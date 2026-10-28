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

    func ledger() -> AcpmuxPendingQuestions {
        let ledger = AcpmuxPendingQuestions()
        ledger.reset(connection: 1)
        return ledger
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
        ledger.observe(Self.snapshot([Self.prompt()], seq: 10), replyTo: "_acpmux/attach", connection: 1)
        ledger.observe(["result": ["events": [Self.record("permission_request", seq: 10, msg: Self.prompt())]]],
                       replyTo: "_acpmux/events", connection: 1)
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
    }

    @Test func snapshotsReconcileWithoutDroppingNewerLiveAsks() throws {
        let ledger = ledger()
        ledger.observe(Self.live(seq: 20), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.observe(Self.snapshot([], seq: 19), replyTo: "_acpmux/attach", connection: 1)
        #expect(ledger.isCurrent(first))
        ledger.observe(Self.snapshot([], seq: 21), replyTo: "_acpmux/attach", connection: 1)
        #expect(!ledger.isCurrent(first))
        ledger.observe(Self.live(seq: 20), replyTo: nil, connection: 1)
        ledger.observe(Self.snapshot([Self.prompt()], seq: 19), replyTo: "_acpmux/attach", connection: 1)
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
        // Current snapshots, including a remote wire's watch, restore pending asks.
        ledger.observe(Self.snapshot([Self.prompt("new")], seq: 22, watch: true), replyTo: "_acpmux/watch", connection: 1)
        #expect(ledger.question(session: "s", permission: "new", connection: 1) != nil)
    }

    @Test func duplicateIsStableButNonceOrQuestionReissueRevokes() throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        ledger.observe(Self.snapshot([Self.prompt()], seq: 11), replyTo: "_acpmux/attach", connection: 1)
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
        #expect(first.requestJSON == AcpmuxSecretKey.canonicalJSON(firstRequest["request"] as Any))
        #expect(second.requestJSON == AcpmuxSecretKey.canonicalJSON(secondRequest["request"] as Any))
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

    @Test func lagRequiresCurrentSnapshotAndReconnectRetiresEveryProof() throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.observe(["method": "_acpmux/lagged", "params": ["sessionIds": ["s"]]], replyTo: nil, connection: 1)
        ledger.observe(Self.live(seq: 11), replyTo: nil, connection: 1)
        #expect(!ledger.isCurrent(first))
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
        ledger.observe(Self.snapshot([Self.prompt()], seq: 12), replyTo: "_acpmux/attach", connection: 1)
        let resumed = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.reset(connection: 2)
        #expect(!ledger.isCurrent(resumed))
        ledger.observe(Self.live(seq: 13), replyTo: nil, connection: 1)
        #expect(ledger.question(session: "s", permission: "p", connection: 2) == nil)
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
        ledger.observe(Self.snapshot([Self.prompt()], seq: 11), replyTo: "_acpmux/attach", connection: 1)
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
        ledger.observe(Self.snapshot([], seq: 12), replyTo: "_acpmux/attach", connection: 1)
        ledger.observe(Self.snapshot([Self.prompt()], seq: 12), replyTo: "_acpmux/attach", connection: 1)
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
    }

    @Test func socketCloseAndSessionPurgeRetireImmediately() throws {
        let ledger = ledger()
        ledger.observe(Self.live(), replyTo: nil, connection: 1)
        let first = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        ledger.observe(["method": "_acpmux/session_changed",
                        "params": ["kind": "purged", "seq": 11, "session": ["sessionId": "s"]]],
                       replyTo: nil, connection: 1)
        ledger.observe(Self.snapshot([Self.prompt()], seq: 10), replyTo: "_acpmux/attach", connection: 1)
        #expect(!ledger.isCurrent(first))
        ledger.reset(connection: 2)
        ledger.observe(Self.live(), replyTo: nil, connection: 2)
        let second = try #require(ledger.question(session: "s", permission: "p", connection: 2))
        ledger.end(connection: 1)
        #expect(ledger.isCurrent(second))
        ledger.end(connection: 2)
        #expect(!ledger.isCurrent(second))
    }

    @Test func malformedUnknownAndModelContentCannotGrantMembership() {
        let ledger = ledger()
        var missingNonce = Self.prompt()
        missingNonce.removeValue(forKey: "decisionNonce")
        ledger.observe(Self.live(missingNonce), replyTo: nil, connection: 1)
        ledger.observe(["result": ["session": ["sessionId": "s", "pending": [Self.prompt()]]]],
                       replyTo: "_acpmux/attach", connection: 1) // no lastSeq
        ledger.observe(["result": ["session": ["sessionId": "s", "lastSeq": 10, "pending": [Self.prompt()]]]],
                       replyTo: "session/prompt", connection: 1) // model's own JSON
        #expect(ledger.question(session: "s", permission: "p", connection: 1) == nil)
    }
}
