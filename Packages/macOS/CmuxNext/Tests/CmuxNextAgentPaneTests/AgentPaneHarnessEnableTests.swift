import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// BRING-YOUR-OWN-HARNESS H4, the app's Enable harness sheet. The page asks with
/// `_acpmux/harness_enable {folder, id}` after a click; the relay needs that gesture, checks the
/// folder like every folder param, reads acpmux's own prompt over the unix socket, shows it on its
/// native sheet, and only after the user's Enable adds the prompt's sha256 and sends the frame. The
/// page can never send a sha256 itself.
@MainActor
@Suite(.serialized) struct AgentPaneHarnessEnableTests {
    typealias Rig = AgentPaneGestureTicketTests.Rig

    /// A fake native sheet and a fake acpmux prompt source.
    final class Sheet {
        var shown: [AgentPaneHarnessEnablePrompt] = []
        var asked: [(folder: String, id: String)] = []

        init(on transport: AgentPaneTransport, reply: Bool, prompt: AgentPaneHarnessEnablePrompt?) {
            // A gate of the test's own (other suites use the app-wide one in parallel).
            transport.confirmationGate = AgentPaneConfirmationGate()
            transport.harnessEnablePrompt = { [self] folder, id in
                asked.append((folder, id))
                return prompt
            }
            transport.requestHarnessEnable = { [self] prompt, answer in
                shown.append(prompt)
                answer(reply)
            }
        }
    }

    static func prompt(id: String = "repo-agent", folder: String, sha: String = "c0ffee") -> AgentPaneHarnessEnablePrompt {
        AgentPaneHarnessEnablePrompt(id: id, folder: folder, path: folder + "/.cmux/harnesses/\(id).toml",
                                     argv: ["node", "./agent.js", "--acp"], program: "/usr/local/bin/node",
                                     env: [.init(key: "TOKEN", source: .keychain("cmux-harness/repo-agent/TOKEN"))],
                                     checkedFiles: [folder + "/agent.js"], warnings: [], sha256: sha)
    }

    /// A real folder (the folder rule resolves paths on disk), the pane's root.
    static func folder() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("harness-enable-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return try #require(AcpmuxPathPolicy.canonical(path))
    }

    func send(_ rig: Rig, _ params: [String: Any], gesture: Bool = true) async -> AgentPaneTransportError? {
        if gesture { rig.transport.gestures.record() }
        return await rig.send("_acpmux/harness_enable", params, ticket: nil)
    }

    func daemonFrames(_ rig: Rig) -> [String] {
        (rig.server.peers.last?.frames ?? []).filter { $0.contains("_acpmux/harness_enable") }
    }

    @Test func aPageSha256IsRefusedAndNeverReachesTheDaemon() async throws {
        let rig = Rig()
        let folder = try Self.folder()
        rig.model.workspaceRoots = { [folder] }
        try await rig.start()
        defer { rig.server.stop() }
        let sheet = Sheet(on: rig.transport, reply: true, prompt: Self.prompt(folder: folder))
        #expect(await send(rig, ["folder": folder, "id": "repo-agent", "sha256": "c0ffee"]) == .intentInvalid)
        #expect(sheet.shown.isEmpty)
        #expect(daemonFrames(rig).isEmpty)
    }

    @Test func withoutAGestureNoSheetOpens() async throws {
        let rig = Rig()
        let folder = try Self.folder()
        rig.model.workspaceRoots = { [folder] }
        try await rig.start()
        defer { rig.server.stop() }
        let sheet = Sheet(on: rig.transport, reply: true, prompt: Self.prompt(folder: folder))
        #expect(await send(rig, ["folder": folder, "id": "repo-agent"], gesture: false) == .gestureRequired)
        #expect(sheet.shown.isEmpty)
        #expect(daemonFrames(rig).isEmpty)
    }

    @Test func enableSendsAcpmuxsOwnSha256AfterTheSheet() async throws {
        let rig = Rig()
        let folder = try Self.folder()
        rig.model.workspaceRoots = { [folder] }
        try await rig.start()
        defer { rig.server.stop() }
        let sheet = Sheet(on: rig.transport, reply: true, prompt: Self.prompt(folder: folder, sha: "5ca1ab1e"))
        #expect(await send(rig, ["folder": folder, "id": "repo-agent"]) == nil)
        #expect(sheet.asked.map(\.id) == ["repo-agent"])
        #expect(sheet.asked.map(\.folder) == [folder])
        #expect(sheet.shown.map(\.sha256) == ["5ca1ab1e"])
        #expect(await rig.server.wait { $0.last?.frames.contains { $0.contains("_acpmux/harness_enable") } == true })
        let sent = try #require(daemonFrames(rig).first)
        let params = try #require((try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])?["params"] as? [String: Any])
        #expect(params["sha256"] as? String == "5ca1ab1e")
        #expect(params["id"] as? String == "repo-agent")
        #expect(params["folder"] as? String == folder)
    }

    @Test func cancelOrNoPromptOrNoSheetRefuses() async throws {
        let rig = Rig()
        let folder = try Self.folder()
        rig.model.workspaceRoots = { [folder] }
        try await rig.start()
        defer { rig.server.stop() }
        let cancel = Sheet(on: rig.transport, reply: false, prompt: Self.prompt(folder: folder))
        #expect(await send(rig, ["folder": folder, "id": "repo-agent"]) == .harnessNotConfirmed)
        #expect(cancel.shown.count == 1)
        // acpmux gave no prompt (no trusted answer, an invalid file): nothing to show, nothing sent.
        let none = Sheet(on: rig.transport, reply: true, prompt: nil)
        #expect(await send(rig, ["folder": folder, "id": "repo-agent"]) == .harnessNotConfirmed)
        #expect(none.shown.isEmpty)
        // A prompt for another id than the page named is not shown.
        let other = Sheet(on: rig.transport, reply: true, prompt: Self.prompt(id: "other", folder: folder))
        #expect(await send(rig, ["folder": folder, "id": "repo-agent"]) == .harnessNotConfirmed)
        #expect(other.shown.isEmpty)
        // A pane without a window has no sheet.
        rig.transport.requestHarnessEnable = nil
        #expect(await send(rig, ["folder": folder, "id": "repo-agent"]) == .harnessNotConfirmed)
        #expect(daemonFrames(rig).isEmpty)
    }

    @Test func aFolderOutsideThePaneIsRefusedBeforeAnyPrompt() async throws {
        let rig = Rig()
        let root = try Self.folder()
        let elsewhere = try Self.folder()
        rig.model.workspaceRoots = { [root] }
        try await rig.start()
        defer { rig.server.stop() }
        let sheet = Sheet(on: rig.transport, reply: true, prompt: Self.prompt(folder: elsewhere))
        #expect(await send(rig, ["folder": elsewhere, "id": "repo-agent"]) == .pathOutsideRoots)
        #expect(sheet.asked.isEmpty)
        #expect(daemonFrames(rig).isEmpty)
    }

    @Test func thePromptParsesOnlyACompleteAnswer() throws {
        let full: [String: Any] = ["prompt": [
            "id": "a", "folder": "/r", "path": "/r/.cmux/harnesses/a.toml", "argv": ["a", "--acp"], "program": NSNull(),
            "env": [["key": "P", "source": "plain", "value": "1"], ["key": "K", "source": "keychain", "item": "s/a"],
                    ["key": "H", "source": "env", "variable": "HOME"]],
            "checkedFiles": [], "warnings": ["w"], "sha256": "ab",
        ]]
        let prompt = try #require(AgentPaneHarnessEnablePrompt(result: full))
        #expect(prompt.program == nil)
        #expect(prompt.env.map(\.source) == [.plain("1"), .keychain("s/a"), .login("HOME")])
        var noHash = full["prompt"] as! [String: Any]
        noHash["sha256"] = ""
        #expect(AgentPaneHarnessEnablePrompt(result: ["prompt": noHash]) == nil)
        var oddSource = full["prompt"] as! [String: Any]
        oddSource["env"] = [["key": "X", "source": "file"]]
        #expect(AgentPaneHarnessEnablePrompt(result: ["prompt": oddSource]) == nil)
    }

    /// The sheet shows every fact, with control and bidi characters written out.
    @Test func theSheetShowsTheCommandWithHiddenCharactersWrittenOut() {
        var prompt = Self.prompt(folder: "/repo")
        prompt.argv = ["node", "a\u{202E}sj.b", "x y"]
        let spec = AgentPaneView.harnessEnableSpec(prompt)
        let text = spec.lines.joined(separator: "\n")
        #expect(text.contains("\\u{202e}"))
        #expect(!text.contains("\u{202E}"))
        #expect(text.contains("'x y'"))
        #expect(text.contains("cmux-harness/repo-agent/TOKEN"))
        #expect(text.contains(prompt.sha256))
        #expect(spec.defaultButton == nil, "Return must not enable a harness")
        #expect(spec.buttons.contains { $0.id == "enable" })
    }
}
