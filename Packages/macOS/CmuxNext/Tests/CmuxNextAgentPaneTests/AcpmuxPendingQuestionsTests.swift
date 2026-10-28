import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Current pending membership is separate from nonce/option history. These frames are the
/// daemon's fixed protocol locations; replayed history never grants a new keyboard answer.
struct AcpmuxPendingQuestionsTests {
    static let nonce = String(repeating: "ab", count: 32)
    static let instance = String(repeating: "c", count: 32)

    static func prompt(_ id: String = "p", nonce: String = nonce, label: String = "Which?", option: String = "yes") -> [String: Any] {
        ["permissionId": id, "decisionNonce": nonce, "personInstance": instance,
         "request": ["options": [["optionId": option, "kind": "allow_once"], ["optionId": "no", "kind": "reject_once"]],
                     "toolCall": ["toolCallId": "call", "_meta": ["acpmux": ["question":
                         ["harness": "codex", "items": [["id": "q", "prompt": label, "options": [], "allowsOther": true]]]]]]]]
    }

    static func live(_ prompt: [String: Any] = prompt(), seq: Int = 10, session: String = "s") -> [String: Any] {
        ["method": "_acpmux/permission_pending", "params": prompt.merging(["sessionId": session, "seq": seq]) { _, new in new }]
    }

    static func record(_ kind: String, seq: Int, session: String = "s", msg: [String: Any] = ["permissionId": "p"]) -> [String: Any] {
        ["sessionId": session, "dir": "mux", "kind": kind, "seq": seq, "msg": msg]
    }

    static func event(_ kind: String, seq: Int, session: String = "s", msg: [String: Any] = ["permissionId": "p"]) -> [String: Any] {
        ["method": "_acpmux/event", "params": record(kind, seq: seq, session: session, msg: msg)]
    }

    static func snapshot(_ pending: [[String: Any]], seq: Int, session: String = "s", watch: Bool = false) -> [String: Any] {
        let detail: [String: Any] = ["sessionId": session, "lastSeq": seq, "pending": pending]
        return ["result": watch ? ["sessions": [detail]] : ["session": detail]]
    }

    func enableWatch(_ ledger: AcpmuxPendingQuestions, connection: Int = 1, token: Int = 900) {
        ledger.request(method: "_acpmux/watch", session: nil, watchEnabled: true, token: token, connection: connection)
        ledger.observe(["result": ["sessions": []]], replyTo: "_acpmux/watch",
                       connection: connection, snapshotRequestToken: token)
    }

    func ledger(watching: Bool = true) -> AcpmuxPendingQuestions {
        let ledger = AcpmuxPendingQuestions()
        ledger.reset(connection: 1)
        if watching { enableWatch(ledger) }
        return ledger
    }

    func read(_ ledger: AcpmuxPendingQuestions, _ frame: [String: Any],
              method: String = "_acpmux/attach", token: Int = 90) {
        ledger.request(method: method, session: "s", watchEnabled: nil, token: token, connection: 1)
        ledger.observe(frame, replyTo: method, connection: 1, snapshotRequestToken: token)
    }

    @Test func livePendingOwnsExactRequestAndSession() throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let question = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        #expect(question.decisionNonce == Self.nonce)
        #expect(question.personInstance == Self.instance)
        #expect(question.allowOnce == ["yes"])
        #expect(question.answerKeys == ["q", "Which?"])
        #expect(ledger.isCurrent(question))
        #expect(ledger.question(session: "other", permission: "p", connection: 1) == nil)
        #expect(ledger.question(session: "s", permission: "p", connection: 0) == nil)
        // One sighting from another session never changes this question's options.
        ledger.observe(Self.live(Self.prompt(option: "other"), session: "other"), replyTo: nil, connection: 1)
        #expect(ledger.isCurrent(question))
        #expect(ledger.question(session: "other", permission: "p", connection: 1)?.allowOnce == ["other"])
    }

    @Test(arguments: ["_acpmux/attach", "_acpmux/events", "_acpmux/watch"])
    func historyCannotOpenAnAsk(method: String) {
        let ledger = ledger()
        ledger.observe(["result": ["events": [Self.record("permission_request", seq: 10, msg: Self.prompt())]]],
                       replyTo: method, connection: 1)
        ledger.observe(Self.event("permission_request", seq: 10, msg: Self.prompt()), replyTo: nil, connection: 1)
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
    }

    @Test func settlementAndLateHistoryNeverReopen() throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.observe(Self.event("permission_decision", seq: 11), replyTo: nil, connection: 1)
        #expect(!ledger.isCurrent(first))
        ledger.observe(Self.live(seq: 10), replyTo: nil, connection: 1)
        read(ledger, Self.snapshot([Self.prompt()], seq: 10), method: "_acpmux/attach")
        ledger.observe(["result": ["events": [Self.record("permission_request", seq: 10, msg: Self.prompt())]]],
                       replyTo: "_acpmux/events", connection: 1)
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
    }

    @Test func snapshotsReconcileWithoutDroppingNewerLiveAsks() throws {
        let ledger = ledger()
        ledger.observe(Self.live(seq: 20), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        read(ledger, Self.snapshot([], seq: 19), method: "_acpmux/attach")
        #expect(ledger.isCurrent(first))
        read(ledger, Self.snapshot([], seq: 21), method: "_acpmux/attach")
        #expect(!ledger.isCurrent(first))
        ledger.observe(Self.live(seq: 20), replyTo: nil, connection: 1)
        read(ledger, Self.snapshot([Self.prompt()], seq: 19), method: "_acpmux/attach")
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
        // A remote wire's watch contains attach detail; normal local watch summaries do not.
        read(ledger, Self.snapshot([Self.prompt("new")], seq: 22, watch: true), method: "_acpmux/watch")
        #expect(ledger.question(session: "s", permission: "new", connection: 1) != nil)
    }

    @Test func duplicateIsStableButNonceOrQuestionReissueRevokes() throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        read(ledger, Self.snapshot([Self.prompt()], seq: 11), method: "_acpmux/attach")
        #expect(ledger.isCurrent(first))
        let reissued = Self.prompt(nonce: String(repeating: "de", count: 32), label: "New question?", option: "new")
        ledger.observe(Self.event("permission_reissued", seq: 12, msg: reissued), replyTo: nil, connection: 1)
        let next = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        #expect(!ledger.isCurrent(first))
        #expect(next.generation != first.generation)
        #expect(next.allowOnce == ["new"])
        #expect(next.answerKeys == ["q", "New question?"])
        ledger.observe(Self.live(seq: 10), replyTo: nil, connection: 1)
        ledger.observe(Self.event("permission_decision", seq: 10), replyTo: nil, connection: 1)
        #expect(ledger.isCurrent(next))
    }

    @Test func optionOrPreviewReissueWithEqualKeysRevokesAndRetainsExactRequest() throws {
        let ledger = ledger()
        func choice(_ label: String, preview: String) -> [String: Any] {
            ["permissionId": "p", "decisionNonce": Self.nonce, "personInstance": Self.instance,
             "request": ["options": [["optionId": "yes", "kind": "allow_once"]],
                         "toolCall": ["toolCallId": "call", "_meta": ["acpmux": ["question":
                             ["harness": "claude", "items": [["id": "q", "prompt": "Which?", "allowsOther": true,
                                 "options": [["id": "choice", "label": label,
                                              "preview": ["text": preview, "format": "html"]]]]]]]]]]]
        }
        let firstRequest = choice("Glass", preview: "<b>old</b>")
        ledger.observe(Self.live(firstRequest), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        let secondRequest = choice("Paper", preview: "<i>new</i>")
        ledger.observe(Self.live(secondRequest, seq: 11), replyTo: nil, connection: 1)
        let second = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        #expect(first.answerKeys == second.answerKeys)
        #expect(first.allowOnce == second.allowOnce)
        #expect(first.decisionNonce == second.decisionNonce)
        #expect(!ledger.isCurrent(first))
        #expect(ledger.isCurrent(second))
        #expect(first.generation != second.generation)
        #expect(first.requestDigest != second.requestDigest)
        // The native snapshot retains full options/previews, not a later page-supplied body.
        let firstBody = try #require(firstRequest["request"])
        let secondBody = try #require(secondRequest["request"])
        #expect(first.requestJSON == AcpmuxSecretKey.canonicalJSON(firstBody))
        #expect(second.requestJSON == AcpmuxSecretKey.canonicalJSON(secondBody))
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(second.requestJSON.utf8)) as? [String: Any])
        #expect(AcpmuxSecretKey.canonicalDigest(decoded) == second.requestDigest)
    }

    @Test func sameSequenceConflictingRequestFailsClosed() throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.observe(Self.live(Self.prompt(option: "changed")), replyTo: nil, connection: 1)
        #expect(!ledger.isCurrent(first))
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
    }

    @Test(arguments: ["turn_end", "turn_result"])
    func turnEndRetiresCurrentProof(kind: String) throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.observe(Self.event(kind, seq: 11, msg: [:]), replyTo: nil, connection: 1)
        #expect(!ledger.isCurrent(first))
        ledger.observe(Self.live(seq: 10), replyTo: nil, connection: 1)
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
    }

    @Test(arguments: ["permission_decision", "turn_end", "turn_result"])
    func watcherSettlementRetiresUntilFreshPendingRead(kind: String) throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        let summary: [String: Any] = ["sessionId": "s", "pendingPermissions": 0, "status": "waiting"]
        ledger.observe(["method": "_acpmux/session_changed",
                        "params": ["sessionId": "s", "kind": kind, "recordKind": kind,
                                   "seq": 11, "session": summary]],
                       replyTo: nil, connection: 1)
        #expect(!ledger.isCurrent(first))
        ledger.observe(Self.live(seq: 10), replyTo: nil, connection: 1)
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
        let replacement = Self.prompt(nonce: String(repeating: "d", count: 64))
        read(ledger, Self.snapshot([replacement], seq: 12), method: "_acpmux/attach")
        let next = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        #expect(next.decisionNonce == String(repeating: "d", count: 64))
    }

    @Test func realWatchSummaryCanRetireButCannotOpenAnAsk() throws {
        let ledger = ledger()
        read(ledger, ["result": ["sessions": [["sessionId": "s", "lastSeq": 10,
                                                "pendingPermissions": 1]]]], method: "_acpmux/watch")
        #expect(ledger.questions(connection: 1).isEmpty)
        ledger.observe(Self.live(seq: 11), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        read(ledger, ["result": ["sessions": [["sessionId": "s", "lastSeq": 12,
                                                "pendingPermissions": 0]]]], method: "_acpmux/watch")
        #expect(!ledger.isCurrent(first))
        ledger.observe(Self.live(seq: 11), replyTo: nil, connection: 1)
        #expect(ledger.questions(connection: 1).isEmpty)
    }

    @Test(arguments: ["_acpmux/detach", "_acpmux/watch"])
    func detachOrWatchOffInvalidatesInFlightReads(method: String) throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.request(method: "_acpmux/attach", session: "s", watchEnabled: nil, token: 1, connection: 1)
        ledger.request(method: method, session: "s", watchEnabled: false, token: 2, connection: 1)
        #expect(!ledger.isCurrent(first))
        ledger.observe(Self.snapshot([Self.prompt()], seq: 12), replyTo: "_acpmux/attach",
                       connection: 1, snapshotRequestToken: 1)
        #expect(ledger.questions(connection: 1).isEmpty)
        if method == "_acpmux/watch" { enableWatch(ledger) }
        read(ledger, Self.snapshot([Self.prompt()], seq: 13))
        #expect(ledger.question(session: "s", permission: "p", connection: 1) != nil)
    }

    @Test func snapshotTokenIsNativeCorrelatedSingleUseAndCancelledReadsCannotRecover() throws {
        let ledger = ledger()
        let ids = AcpmuxRequestIds()
        let token = try #require(ids.begin(pageID: "7", method: "_acpmux/attach"))
        ledger.request(method: "_acpmux/attach", session: "s", watchEnabled: nil, token: token, connection: 1)
        let daemon = #"{"id":TOKEN,"result":{"session":{"sessionId":"s","lastSeq":10,"pending":[]}}}"#
            .replacingOccurrences(of: "TOKEN", with: String(token))
        if case .page(_, let object, let method, let nativeToken) = ids.toPage(daemon) {
            #expect(nativeToken == token)
            ledger.observe(object, replyTo: method, connection: 1, snapshotRequestToken: nativeToken)
        } else { Issue.record("matched daemon reply must retain the native relay token") }
        // No request owns this repeated token; the new request body cannot reopen a card.
        ledger.observe(Self.snapshot([Self.prompt()], seq: 11), replyTo: "_acpmux/attach",
                       connection: 1, snapshotRequestToken: token)
        #expect(ledger.questions(connection: 1).isEmpty)
        ledger.request(method: "_acpmux/attach", session: "s", watchEnabled: nil, token: 9, connection: 1)
        ledger.snapshotRequestCancelled(token: 9, connection: 1)
        ledger.observe(Self.snapshot([Self.prompt()], seq: 12), replyTo: "_acpmux/attach",
                       connection: 1, snapshotRequestToken: 9)
        #expect(ledger.questions(connection: 1).isEmpty)
    }

    @Test func lagKeepsSequenceFloorAndRejectsPreGapSnapshot() throws {
        let ledger = ledger()
        ledger.observe(Self.live(seq: 10), replyTo: nil, connection: 1)
        ledger.observe(Self.live(seq: 20), replyTo: nil, connection: 1)
        ledger.observe(["method": "_acpmux/event", "params":
            ["sessionId": "s", "dir": "in", "kind": "session/update", "seq": 22, "msg": [:]]],
                       replyTo: nil, connection: 1)
        ledger.request(method: "_acpmux/attach", session: "s", watchEnabled: nil, token: 1, connection: 1)
        ledger.observe(["method": "_acpmux/lagged", "params": ["sessionIds": ["s"]]],
                       replyTo: nil, connection: 1)
        // An in-flight request from before the gap is discarded, even if its body claims a
        // sequence newer than the last live frame; the response has no post-gap native token.
        ledger.observe(Self.snapshot([Self.prompt()], seq: 25), replyTo: "_acpmux/attach",
                       connection: 1, snapshotRequestToken: 1)
        #expect(ledger.questions(connection: 1).isEmpty)
        read(ledger, Self.snapshot([Self.prompt(nonce: String(repeating: "d", count: 64))], seq: 15))
        #expect(ledger.questions(connection: 1).isEmpty)
        // A post-gap watch is only a summary. Its positive count cannot restore identity.
        read(ledger, ["result": ["sessions": [["sessionId": "s", "lastSeq": 21,
                                                "pendingPermissions": 1]]]], method: "_acpmux/watch")
        #expect(ledger.questions(connection: 1).isEmpty)
        read(ledger, Self.snapshot([Self.prompt()], seq: 21))
        #expect(ledger.questions(connection: 1).isEmpty) // the non-mux event's floor survived too
        ledger.request(method: "_acpmux/attach", session: "s", watchEnabled: nil, token: 2, connection: 1)
        ledger.observe(Self.snapshot([Self.prompt(nonce: String(repeating: "d", count: 64))], seq: 24),
                       replyTo: "_acpmux/attach", connection: 1, snapshotRequestToken: 2)
        #expect(ledger.question(session: "s", permission: "p", connection: 1) != nil)
    }

    @Test func lagRequiresCurrentSnapshotAndReconnectRetiresEveryProof() throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.observe(["method": "_acpmux/lagged", "params": ["sessionIds": ["s"]]], replyTo: nil, connection: 1)
        ledger.observe(Self.live(seq: 11), replyTo: nil, connection: 1)
        #expect(!ledger.isCurrent(first))
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
        ledger.request(method: "_acpmux/attach", session: "s", watchEnabled: nil, token: 9, connection: 1)
        ledger.observe(Self.snapshot([Self.prompt()], seq: 12), replyTo: "_acpmux/attach",
                       connection: 1, snapshotRequestToken: 9)
        let resumed = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.reset(connection: 2)
        #expect(!ledger.isCurrent(resumed))
        ledger.observe(Self.live(seq: 13), replyTo: nil, connection: 1)
        #expect(ledger.question(session: "s", permission: "p", connection: 2) == nil)
        enableWatch(ledger, connection: 2)
        ledger.observe(Self.live(seq: 13), replyTo: nil, connection: 2)
        let reconnected = try #require(ledger.question(session: "s", permission: "p", connection: 2))
        #expect(reconnected.generation != resumed.generation)
        ledger.reset(connection: nil)
        #expect(!ledger.isCurrent(reconnected))
    }

    @Test func settlementBeforeDelayedPendingAndRepeatedSnapshotCannotReopen() {
        let ledger = ledger()
        ledger.observe(Self.event("permission_decision", seq: 11), replyTo: nil, connection: 1)
        ledger.observe(Self.live(seq: 10), replyTo: nil, connection: 1)
        read(ledger, Self.snapshot([Self.prompt()], seq: 11), method: "_acpmux/attach")
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
        read(ledger, Self.snapshot([], seq: 12), method: "_acpmux/attach")
        read(ledger, Self.snapshot([Self.prompt()], seq: 12), method: "_acpmux/attach")
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
    }

    @Test func socketCloseAndSessionPurgeRetireImmediately() throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.observe(["method": "_acpmux/session_changed",
                        "params": ["kind": "purged", "seq": 11, "session": ["sessionId": "s"]]],
                       replyTo: nil, connection: 1)
        read(ledger, Self.snapshot([Self.prompt()], seq: 10), method: "_acpmux/attach")
        #expect(!ledger.isCurrent(first))
        ledger.reset(connection: 2)
        enableWatch(ledger, connection: 2)
        ledger.observe(Self.live(), replyTo: nil, connection: 2)
        let second = try #require(ledger.question(session: "s", permission: "p", connection: 2))
        ledger.end(connection: 1)
        #expect(ledger.isCurrent(second))
        ledger.end(connection: 2)
        #expect(!ledger.isCurrent(second))
    }

    @Test func attachmentCannotSupplyUnfilteredLifecycleCoverage() throws {
        let ledger = ledger(watching: false)
        func attach(kinds: [String], token: Int) {
            let box = AgentPaneTransport.FrameBox(["method": "_acpmux/attach",
                "params": ["sessionId": "s", "eventStream": true, "kinds": kinds]])
            let fields = box.questionLifecycle()
            ledger.request(method: fields.method, session: fields.session, watchEnabled: fields.watchEnabled,
                           token: token, connection: 1)
            ledger.observe(Self.snapshot([Self.prompt()], seq: token), replyTo: fields.method,
                           connection: 1, snapshotRequestToken: token)
            ledger.observe(Self.live(seq: token + 1), replyTo: nil, connection: 1)
        }
        attach(kinds: [], token: 10)
        #expect(ledger.questions(connection: 1).isEmpty)
        // Neither an unfiltered attachment nor replacing it with an empty filter owns coverage.
        attach(kinds: ["all"], token: 12)
        attach(kinds: [], token: 14)
        #expect(ledger.questions(connection: 1).isEmpty)
        enableWatch(ledger)
        read(ledger, Self.snapshot([Self.prompt()], seq: 16))
        let question = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.request(method: "_acpmux/watch", session: nil, watchEnabled: false, token: 17, connection: 1)
        attach(kinds: [], token: 18)
        #expect(!ledger.isCurrent(question))
        #expect(ledger.questions(connection: 1).isEmpty)
    }

    @Test func watchNeedsCurrentNativeAckAndContinuesAcrossNewQuestions() throws {
        let ledger = ledger(watching: false)
        ledger.request(method: "_acpmux/watch", session: nil, watchEnabled: true, token: 1, connection: 1)
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        #expect(ledger.questions(connection: 1).isEmpty) // A sent request is not an ACK.
        ledger.request(method: "_acpmux/watch", session: nil, watchEnabled: false, token: 2, connection: 1)
        ledger.observe(["result": ["sessions": []]], replyTo: "_acpmux/watch",
                       connection: 1, snapshotRequestToken: 1)
        read(ledger, Self.snapshot([Self.prompt()], seq: 11))
        #expect(ledger.questions(connection: 1).isEmpty) // The old enable cannot outlive watch-off.
        enableWatch(ledger)
        read(ledger, Self.snapshot([Self.prompt()], seq: 12))
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.observe(["method": "_acpmux/session_changed", "params": ["seq": 13,
            "recordKind": "permission_decision", "session": ["sessionId": "s", "pendingPermissions": 0]]],
                       replyTo: nil, connection: 1)
        #expect(!ledger.isCurrent(first))
        ledger.observe(Self.live(Self.prompt("next"), seq: 14), replyTo: nil, connection: 1)
        let next = try #require(ledger.question(session: "s", permission: "next", connection: 1))
        #expect(ledger.isCurrent(next)) // No watch toggle or new attachment between A and B.
    }

    @Test(arguments: ["purged", "stale"])
    func zeroSequencePeerInvalidationCannotBeDismissedAsOldHistory(notice: String) throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.request(method: "_acpmux/attach", session: "s", watchEnabled: nil, token: 1, connection: 1)
        ledger.observe(["method": "_acpmux/session_changed", "params": ["seq": 0, "peer": "peer",
            "kind": notice == "purged" ? "purged" : "status",
            "session": ["sessionId": "s", "stale": notice == "stale"]]],
                       replyTo: nil, connection: 1)
        #expect(!ledger.isCurrent(first))
        ledger.observe(Self.snapshot([Self.prompt()], seq: 11), replyTo: "_acpmux/attach",
                       connection: 1, snapshotRequestToken: 1)
        ledger.observe(["method": "_acpmux/session_changed", "params": ["seq": 0,
            "kind": "status", "session": ["sessionId": "s", "stale": false]]],
                       replyTo: nil, connection: 1)
        ledger.observe(Self.live(seq: 11), replyTo: nil, connection: 1)
        #expect(ledger.questions(connection: 1).isEmpty)
        read(ledger, ["result": ["session": ["sessionId": "s", "lastSeq": 12,
                                            "stale": true, "pending": [Self.prompt()]]]])
        #expect(ledger.questions(connection: 1).isEmpty)
        read(ledger, Self.snapshot([Self.prompt(nonce: String(repeating: "d", count: 64))], seq: 13))
        let recovered = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        #expect(recovered.generation != first.generation)
        #expect(!ledger.isCurrent(first))
    }

    @Test func malformedUnknownAndModelContentCannotGrantMembership() {
        let ledger = ledger()
        var missingNonce = Self.prompt()
        missingNonce.removeValue(forKey: "decisionNonce")
        ledger.observe(Self.live(missingNonce), replyTo: nil, connection: 1)
        read(ledger, ["result": ["session": ["sessionId": "s", "pending": [Self.prompt()]]]]) // no lastSeq
        ledger.observe(["result": ["session": ["sessionId": "s", "lastSeq": 10, "pending": [Self.prompt()]]]],
                       replyTo: "session/prompt", connection: 1) // model's own JSON
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
    }
}
