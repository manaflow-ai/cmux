import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `answers` on `_acpmux/permission_respond` (plans/cmux-next/agent-questions.md): the relay lets
/// page answers through only to a pending question (`request.toolCall._meta.acpmux.question` is an
/// object), keyed by that question's items, and bounded: 1 to ``AcpmuxPaneMethods/maximumAnswerItems``
/// items, each key and each string at most ``AcpmuxPaneMethods/maximumAnswerBytes`` UTF-8 bytes,
/// and list strings counted together under that same bound. Anything else is refused as `transport.intent_invalid` and never reaches the
/// daemon; the permission stays pending. An answer is still an allow and needs a fresh gesture.
@MainActor
@Suite(.serialized) struct AgentPaneQuestionAnswersTests {
    nonisolated static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#
    nonisolated static func allowOptions() -> [[String: Any]] {
        [["optionId": "allow_once", "name": "Answer", "kind": "allow_once"],
         ["optionId": "reject_once", "name": "Decline", "kind": "reject_once"]]
    }

    /// A pending permission; with `question`, the daemon's normalized question
    /// (`toolCall._meta.acpmux.question`) with one item per prompt.
    nonisolated static func pending(_ permission: String, question harness: String? = nil, items: [(id: String, prompt: String)] = []) -> [String: Any] {
        var request: [String: Any] = ["options": allowOptions()]
        if let harness {
            let question: [String: Any] = ["harness": harness, "agent": harness, "items": items.map {
                ["id": $0.id, "prompt": $0.prompt, "options": [Any](), "multiSelect": false, "allowsOther": true]
            }]
            request["toolCall"] = ["toolCallId": "t", "_meta": ["acpmux": ["question": question]]]
        }
        return ["jsonrpc": "2.0", "method": "_acpmux/permission_pending",
                "params": ["sessionId": "s", "permissionId": permission, "request": request]]
    }

    nonisolated static func respond(_ id: Int = 1, permission: String, answers: Any) -> String {
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "_acpmux/permission_respond", "params": [
            "sessionId": "s", "permissionId": permission, "optionId": "allow_once", "answers": answers,
        ]]
        let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    /// The relay's off-main check of `text` with a tool permission `p-tool`, a Claude question
    /// `p-claude` ("Which auth?", "Which store?") and a Codex question `p-codex` (items db_engine,
/// service_name).
    nonisolated static func check(_ text: String) -> AgentPaneTransport.Checked {
        let options = AcpmuxPermissionOptions()
        options.observe(pending("p-tool"), replyTo: nil)
        options.observe(pending("p-claude", question: "claude", items: [("q0", "Which auth?"), ("q1", "Which store?")]), replyTo: nil)
        options.observe(pending("p-codex", question: "codex", items: [("db_engine", "Which engine?"), ("service_name", "Name?")]), replyTo: nil)
        let sessions = AcpmuxPaneSessions()
        sessions.add("s")
        let snapshot = AgentPaneTransport.Snapshot(isFirst: false, localAppToken: nil, modeFields: [], sessions: sessions, options: options)
        return AgentPaneTransport.checkOne(text, snapshot)
    }

    nonisolated static func refused(_ text: String) -> Bool {
        guard case .refuse(.refuse(.intentInvalid, method: "_acpmux/permission_respond", requestID: "1"), spend: nil) = check(text) else {
            return false
        }
        return true
    }

    nonisolated static func passes(_ text: String) -> Bool {
        guard case .frame(let facts, _) = check(text) else { return false }
        // An answer is an allow: it still needs a fresh gesture.
        return facts.needsGesture
    }

    @Test func answersOnAToolPermissionAreRefused() {
        #expect(Self.refused(Self.respond(permission: "p-tool", answers: ["Which auth?": "OAuth"])))
        #expect(Self.refused(Self.respond(permission: "p-tool", answers: [String: Any]())))
        // A permission the relay never saw is no question either.
        #expect(Self.refused(Self.respond(permission: "p-unknown", answers: ["Which auth?": "OAuth"])))
    }

    @Test func answersKeyedByTheQuestionsItemsPass() {
        #expect(Self.passes(Self.respond(permission: "p-claude", answers: ["Which auth?": "OAuth", "Which store?": "Disk"])))
        // An item may be named by its id as well as its prompt (the daemon picks the harness's key).
        #expect(Self.passes(Self.respond(permission: "p-claude", answers: ["q0": "OAuth"])))
        // Codex's form (webviews question/model.test.ts "Codex answers by id with arrays").
        #expect(Self.passes(Self.respond(permission: "p-codex", answers: ["db_engine": ["answers": ["SQLite"]]])))
        #expect(Self.passes(Self.respond(permission: "p-codex", answers: ["db_engine": ["answers": ["SQLite"]], "service_name": ["answers": ["ledger"]]])))
        #expect(Self.passes(Self.respond(permission: "p-codex", answers: ["db_engine": ["answers": ["SQLite", "Postgres"]]])))
        #expect(Self.passes(Self.respond(permission: "p-codex", answers: ["db_engine": ["SQLite"]])))
        // A scalar may use all 4096 bytes; a list's strings are counted together.
        #expect(Self.passes(Self.respond(permission: "p-claude", answers: ["Which auth?": String(repeating: "a", count: 4096)])))
        #expect(Self.refused(Self.respond(permission: "p-codex", answers: ["db_engine": ["answers": [String(repeating: "a", count: 2048), String(repeating: "b", count: 2049)]]])))
        // A list holds at most 64 strings.
        #expect(Self.passes(Self.respond(permission: "p-codex", answers: ["db_engine": ["answers": Array(repeating: "SQLite", count: 64)]])))
        #expect(Self.passes(Self.respond(permission: "p-claude", answers: ["Which auth?": Array(repeating: "OAuth", count: 64)])))
    }

    @Test func answersOutsideTheQuestionsItemsOrBoundsAreRefused() {
        let cases: [(String, Any)] = [
            ("unknown item", ["Which auth?": "OAuth", "Other?": "x"]),
            ("another question's item", ["db_engine": "SQLite"]),
            ("not an object", ["OAuth"]),
            ("a string", "OAuth"),
            ("null", NSNull()),
            ("a number", ["Which auth?": 1]),
            ("a bool", ["Which auth?": true]),
            ("an object that is not {answers}", ["Which auth?": ["label": "OAuth"]]),
            ("{answers} beside another key", ["Which auth?": ["answers": ["OAuth"], "x": 1]]),
            ("a list with a number", ["Which auth?": ["OAuth", 1]]),
            ("a nested list", ["Which auth?": [["OAuth"]]]),
            ("a value over 4 KB", ["Which auth?": String(repeating: "a", count: 4097)]),
            ("a value over 4 KB in UTF-8 bytes", ["Which auth?": String(repeating: "é", count: 2049)]),
            ("a list element over 4 KB", ["Which auth?": ["OAuth", String(repeating: "a", count: 4097)]]),
            ("an {answers} element over 4 KB", ["Which auth?": ["answers": [String(repeating: "é", count: 2049)]]]),
            ("a list of 65 strings", ["Which auth?": Array(repeating: "OAuth", count: 65)]),
            ("an {answers} list of 65 strings", ["Which auth?": ["answers": Array(repeating: "OAuth", count: 65)]]),
            ("no items", [String: Any]()),
        ]
        for (name, answers) in cases {
            #expect(Self.refused(Self.respond(permission: "p-claude", answers: answers)), "\(name)")
        }
    }

    /// A permission seen once without a question is no question, whatever frame follows (the policy
    /// crate's `is_question`: every request seen for it was a question).
    @Test func aPermissionSeenAsAToolPermissionNeverTakesAnswers() {
        for order in [[false, true], [true, false]] {
            let options = AcpmuxPermissionOptions()
            for isQuestion in order {
                options.observe(isQuestion ? Self.pending("p-mixed", question: "claude", items: [("q0", "Which auth?")]) : Self.pending("p-mixed"), replyTo: nil)
            }
            let sessions = AcpmuxPaneSessions()
            sessions.add("s")
            let snapshot = AgentPaneTransport.Snapshot(isFirst: false, localAppToken: nil, modeFields: [], sessions: sessions, options: options)
            guard case .refuse(.refuse(.intentInvalid, _, _), _) = AgentPaneTransport.checkOne(Self.respond(permission: "p-mixed", answers: ["Which auth?": "OAuth"]), snapshot) else {
                Issue.record("answers passed for a permission once seen without a question (\(order))")
                continue
            }
        }
    }

    /// An item key over 4 KB is refused even when the question has it.
    @Test func aKeyOverFourKilobytesIsRefused() {
        let long = String(repeating: "q", count: 4097)
        let options = AcpmuxPermissionOptions()
        options.observe(Self.pending("p-long", question: "claude", items: [("q0", long)]), replyTo: nil)
        let sessions = AcpmuxPaneSessions()
        sessions.add("s")
        let snapshot = AgentPaneTransport.Snapshot(isFirst: false, localAppToken: nil, modeFields: [], sessions: sessions, options: options)
        guard case .refuse(.refuse(.intentInvalid, _, _), _) = AgentPaneTransport.checkOne(Self.respond(permission: "p-long", answers: [long: "yes"]), snapshot) else {
            Issue.record("a 4097-byte key passed")
            return
        }
    }

    @Test func moreThanSixtyFourAnswersAreRefused() {
        let prompts = (0..<65).map { "Question \($0)?" }
        let options = AcpmuxPermissionOptions()
        options.observe(Self.pending("p-many", question: "claude", items: prompts.enumerated().map { ("q\($0.offset)", $0.element) }), replyTo: nil)
        let sessions = AcpmuxPaneSessions()
        sessions.add("s")
        let snapshot = AgentPaneTransport.Snapshot(isFirst: false, localAppToken: nil, modeFields: [], sessions: sessions, options: options)
        func refused(_ count: Int) -> Bool {
            let answers = Dictionary(uniqueKeysWithValues: prompts.prefix(count).map { ($0, "yes") })
            guard case .refuse(.refuse(.intentInvalid, _, _), _) = AgentPaneTransport.checkOne(Self.respond(permission: "p-many", answers: answers), snapshot) else {
                return false
            }
            return true
        }
        #expect(!refused(64))
        #expect(refused(65))
    }

    /// End to end: page script without a gesture cannot answer a question; with one, exactly one
    /// answer reaches the daemon. Answers on a tool permission never reach it, gesture or not, and
    /// that refusal leaves the gesture for the next grant.
    @Test func anAnswerNeedsAFreshGestureAndAToolPermissionNeverTakesAnswers() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport()
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        transport.sessions.add("s")
        for frame in [Self.pending("p-tool"), Self.pending("p-claude", question: "claude", items: [("q0", "Which auth?")])] {
            let data = try JSONSerialization.data(withJSONObject: frame)
            server.push(String(decoding: data, as: UTF8.self), to: 0)
        }
        #expect(await eventually { events.flatMap(\.frames).contains { $0.contains("p-claude") } })

        // No gesture: the answer is refused, the socket stays open.
        let answer = Self.respond(7, permission: "p-claude", answers: ["Which auth?": "OAuth"])
        #expect(await transport.send(connection: id, frames: [answer]) == .gestureRequired)
        #expect(transport.connection == id)

        // A gesture, then answers on the tool permission: refused before the gesture rule.
        transport.gestures.record()
        let smuggled = Self.respond(8, permission: "p-tool", answers: ["Which auth?": "OAuth"])
        #expect(await transport.send(connection: id, frames: [smuggled]) == .intentInvalid)
        // The same gesture answers the question once; a second answer needs a new gesture.
        #expect(await transport.send(connection: id, frames: [Self.respond(9, permission: "p-claude", answers: ["Which auth?": "OAuth"])]) == nil)
        #expect(await transport.send(connection: id, frames: [Self.respond(10, permission: "p-claude", answers: ["Which auth?": "Keys"])]) == .gestureRequired)

        #expect(await server.wait { $0.first?.frames.count == 2 })
        let sent = server.peers.first?.frames ?? []
        #expect(sent.contains { $0.contains("OAuth") && $0.contains("p-claude") })
        #expect(!sent.contains { $0.contains("p-tool") || $0.contains("Keys") })
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
