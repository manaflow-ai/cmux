import Foundation
import Testing
@testable import CmuxNextAgentPane

/// ad349's review of b7fc859d5e1. P1: only session/set_mode and session/set_config_option may name a
/// mode; any other method with a mode field (the daemon's `modeFields`, in params or in
/// `_meta.acpmux`) is refused with transport.intent_invalid. Without the daemon's answer, any field
/// outside the method's known params is refused. P2: a set_config_option whose configId is not
/// free (the daemon's `freeConfigIds`) needs the native sheet, unless the daemon says its value asks.
@MainActor
@Suite(.serialized) struct AgentPaneModeFieldTests {
    typealias Rig = AgentPaneGestureTicketTests.Rig
    typealias Sheets = AgentPaneModeConfirmationTests.Sheets

    /// The methods ad349 named, each with params the pane really sends.
    static let methods: [(String, [String: Any])] = [
        ("session/new", ["mcpServers": [Any](), "_meta": ["acpmux": ["harness": "claude"]]]),
        ("acp.session.fork", ["sessionId": "s", "throughSeq": 3]),
        ("_acpmux/warm", ["sessionIds": ["s"], "limit": 2]),
        ("_acpmux/prewarm", ["harness": "claude"]),
        ("_acpmux/handoff_draft", ["handoffId": "h", "revision": 1, "draftKey": "k", "capsule": ["text": "t"]]),
        ("_acpmux/handoff_start", ["handoffId": "h", "revision": 1, "promptId": "p", "capsule": ["text": "t"]]),
    ]

    /// `params` with `field` at the top level, or in `_meta.acpmux`.
    static func with(_ params: [String: Any], _ field: String, inMeta: Bool) -> [String: Any] {
        var params = params
        if inMeta {
            var meta = params["_meta"] as? [String: Any] ?? [:]
            var acpmux = meta["acpmux"] as? [String: Any] ?? [:]
            acpmux[field] = "bypassPermissions"
            meta["acpmux"] = acpmux
            params["_meta"] = meta
        } else {
            params[field] = "bypassPermissions"
        }
        return params
    }

    func daemonSaw(_ rig: Rig, _ needle: String) -> Bool {
        rig.server.peers.last?.frames.contains { $0.contains(needle) } == true
    }

    /// The pane learns that handoff `h` is from its session `s` (the daemon's record names its
    /// source), so its draft and start follow the rules of a session in scope.
    func learnHandoff(_ rig: Rig) async {
        rig.server.answer("_acpmux/handoff_get", with: #"{"handoffId":"h","source":{"sessionId":"s"}}"#)
        #expect(await rig.send("_acpmux/handoff_get", ["handoffId": "h"], ticket: nil) == nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, !rig.transport.sessions.holdsSource(["handoffId": "h"]) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(rig.transport.sessions.holdsSource(["handoffId": "h"]))
    }

    @Test func aModeFieldOnAnyOtherMethodIsRefused() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        #expect(rig.transport.modeFields == AcpmuxAskingModesFake.modeFields, "asked from the daemon at open")
        for (method, params) in Self.methods {
            for field in ["modeId", "permissionMode", "approvalPolicy", "sandbox"] {
                for inMeta in [false, true] {
                    #expect(await rig.send(method, Self.with(params, field, inMeta: inMeta), ticket: nil) == .intentInvalid,
                            "\(method) \(field) meta=\(inMeta)")
                }
            }
        }
        #expect(!daemonSaw(rig, "bypassPermissions"))
        // The same frames with no mode field pass (session/new is left out: its cwd rules are not
        // this test's).
        await learnHandoff(rig)
        for (method, params) in Self.methods.dropFirst() {
            #expect(await rig.send(method, params, ticket: nil) == nil, "\(method)")
        }
        // The known params apply also while the daemon answers: its fields are an extra deny.
        #expect(await rig.send("acp.session.fork", ["sessionId": "s", "throughSeq": 3, "note": 1], ticket: nil) == .intentInvalid)
    }

    /// ad349: `_meta` may hold only `acpmux` (and `cmuxGesture` on a redeeming frame), on every path.
    /// A mode set through another `_meta` namespace is refused while web_modes answers.
    @Test func aModeInAnotherMetaNamespaceIsRefusedWhileTheDaemonAnswers() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        #expect(rig.transport.modeFields != nil)
        let claudeCode: [String: Any] = ["options": ["permissionMode": "bypassPermissions"]]
        #expect(await rig.send("session/new", ["mcpServers": [Any](), "_meta": ["acpmux": ["harness": "claude"], "claudeCode": claudeCode]],
                               ticket: nil) == .intentInvalid)
        #expect(await rig.send("acp.session.fork", ["sessionId": "s", "throughSeq": 3, "_meta": ["claudeCode": claudeCode]], ticket: nil)
            == .intentInvalid)
        // An acpmux key outside the method's list, and a _meta that is not an object.
        #expect(await rig.send("session/new", ["mcpServers": [Any](), "_meta": ["acpmux": ["harness": "claude", "yolo": true]]], ticket: nil)
            == .intentInvalid)
        #expect(await rig.send("session/prompt", ["sessionId": "s", "prompt": [Any](), "_meta": "x"], ticket: nil) == .intentInvalid)
        // set_mode without a ticket: _meta may hold only acpmux, so another key is refused.
        rig.transport.gestures.record()
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "plan", "_meta": ["claudeCode": claudeCode]], ticket: nil)
            == .intentInvalid)
        #expect(!rig.server.peers.last!.frames.contains { $0.contains("bypassPermissions") })
    }

    @Test func withoutTheDaemonsFieldsOnlyKnownParamsPass() async throws {
        let rig = Rig()
        rig.webModes = { _, _, _ in nil }
        try await rig.start()
        defer { rig.server.stop() }
        #expect(rig.transport.modeFields == nil)
        #expect(await rig.send("acp.session.fork", ["sessionId": "s", "throughSeq": 3, "note": 1], ticket: nil) == .intentInvalid)
        #expect(await rig.send("session/new", ["mcpServers": [Any](), "_meta": ["acpmux": ["harness": "claude", "yolo": true]]], ticket: nil)
            == .intentInvalid)
        #expect(await rig.send("session/prompt", ["sessionId": "s", "prompt": [Any](), "_meta": ["acpmux": ["permissionMode": "x"]]], ticket: nil)
            == .intentInvalid)
        #expect(await rig.send("_acpmux/prewarm", ["harness": "claude", "mode": "x"], ticket: nil) == .intentInvalid)
        #expect(!daemonSaw(rig, "yolo"))
        // What the pane really sends passes.
        await learnHandoff(rig)
        for (method, params) in Self.methods.dropFirst() {
            #expect(await rig.send(method, params, ticket: nil) == nil, "\(method)")
        }
        // A prompt also needs a live gesture.
        rig.transport.gestures.record()
        #expect(await rig.send("session/prompt", ["sessionId": "s", "prompt": [Any](), "_meta": ["acpmux": ["promptId": "p"]]], ticket: nil) == nil)
    }

    @Test func aConfigOptionThatIsNotFreeNeedsTheSheet() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let fast: [String: Any] = ["method": "session/set_config_option", "params": ["configId": "fast", "value": true]]
        // No sheet to show: refused.
        rig.model.onConfirmMode = nil
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "fast", "value": true],
                               ticket: await rig.ticket(fast)) == .modeNotConfirmed)
        #expect(!daemonSaw(rig, "\"fast\""))
        // Confirmed: passes, and the sheet names the option and its value.
        let sheets = Sheets(on: rig.transport, reply: true)
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "fast", "value": true],
                               ticket: await rig.ticket(fast)) == nil)
        #expect(sheets.requests == [.option(id: "fast", value: "true")])
        // A free option needs no sheet.
        let effort: [String: Any] = ["method": "session/set_config_option", "params": ["configId": "effort", "value": "high"]]
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "effort", "value": "high"],
                               ticket: await rig.ticket(effort)) == nil)
        #expect(sheets.asked.count == 1)
    }

    @Test func withoutTheDaemonEveryConfigOptionNeedsTheSheet() async throws {
        let rig = Rig()
        rig.webModes = { _, _, _ in nil }
        try await rig.start()
        defer { rig.server.stop() }
        let sheets = Sheets(on: rig.transport, reply: false)
        let effort: [String: Any] = ["method": "session/set_config_option", "params": ["configId": "effort", "value": "high"]]
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "effort", "value": "high"],
                               ticket: await rig.ticket(effort)) == .modeNotConfirmed)
        #expect(sheets.asked == ["effort = high"])
    }

    /// An option that is not free shows its id and value.
    @Test func aNonModeOptionShowsTheOptionText() {
        let option = AgentPaneView.confirmationSpec(.option(id: "fast", value: "true"))
        #expect(option.lines == [String(format: AgentPaneView.confirmOptionMessage, "fast", "true")])
        #expect(option.lines.first?.contains("fast") == true && option.lines.first?.contains("true") == true)
    }
}
