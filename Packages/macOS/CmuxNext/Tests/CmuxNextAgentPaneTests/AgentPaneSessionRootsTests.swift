import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A chat that the sidebar switched the pane to may live in another project: its own folder (the
/// cwd the daemon reports for it) is a root for `file.open` and `link.openPath`, but only for a
/// session in the pane's scope, and never `/` or the home folder.
@MainActor
@Suite struct AgentPaneSessionRootsTests {
    struct Fixture {
        let base: URL
        let pane: URL
        let other: URL
        let file: URL

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("session-roots-\(UUID().uuidString)")
            pane = base.appendingPathComponent("pane-project", isDirectory: true)
            other = base.appendingPathComponent("other-project", isDirectory: true)
            try FileManager.default.createDirectory(at: pane, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            file = other.appendingPathComponent("main.swift")
            try Data("x".utf8).write(to: file)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    /// The daemon's reply to `_acpmux/attach` for `session` in `cwd`.
    static func attachReply(_ session: String, cwd: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 7, "result": ["session": ["sessionId": session, "cwd": cwd], "events": []]]
    }

    static func model(_ fixture: Fixture) -> (AgentPaneModel, () -> [String]) {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let pane = fixture.pane.path
        model.workspaceRoots = { [pane] }
        var opened: [String] = []
        model.onOpenFile = { url, _ in
            opened.append(url.resolvingSymlinksInPath().path)
            return true
        }
        return (model, { opened })
    }

    static func open(_ model: AgentPaneModel, _ path: String) async -> [String: Any] {
        model.transport.gestures.record()
        return await model.respond(to: AgentPaneRequest(body: ["method": "file.open", "params": ["path": path, "where": "tab"]] as [String: Any]))
    }

    @Test func theActiveSessionsOwnFolderIsARoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (model, opened) = Self.model(fixture)
        // Before the switch the other project is outside the pane.
        #expect(await Self.open(model, fixture.file.path)["ok"] as? Bool == false)
        model.transport.sessions.add("s2")
        model.transport.sessions.observeFolder(Self.attachReply("s2", cwd: fixture.other.path), replyTo: "_acpmux/attach")
        _ = await model.respond(to: .persistSession("s2"))
        #expect(await Self.open(model, fixture.file.path)["ok"] as? Bool == true)
        #expect(opened() == [fixture.file.resolvingSymlinksInPath().path])
        // The same for a path chip.
        model.transport.gestures.record()
        let chip = await model.respond(to: AgentPaneRequest(body: ["method": "link.openPath", "params": ["path": fixture.file.path]] as [String: Any]))
        #expect(chip["ok"] as? Bool == true)
    }

    @Test func aSessionOutsideThePanesScopeOrAWideFolderAddsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // The page persisted a session the pane never opened: its folder is no root.
        var (model, _) = Self.model(fixture)
        model.transport.sessions.observeFolder(Self.attachReply("s3", cwd: fixture.other.path), replyTo: "_acpmux/attach")
        _ = await model.respond(to: .persistSession("s3"))
        #expect(await Self.open(model, fixture.file.path)["ok"] as? Bool == false)
        // A session whose folder is / or the home folder adds nothing.
        for wide in ["/", NSHomeDirectory()] {
            (model, _) = Self.model(fixture)
            model.transport.sessions.add("s4")
            model.transport.sessions.observeFolder(Self.attachReply("s4", cwd: wide), replyTo: "_acpmux/attach")
            _ = await model.respond(to: .persistSession("s4"))
            #expect(model.sessionRoots().isEmpty, "\(wide)")
        }
        // A reply to another method does not name a folder.
        (model, _) = Self.model(fixture)
        model.transport.sessions.add("s5")
        model.transport.sessions.observeFolder(Self.attachReply("s5", cwd: fixture.other.path), replyTo: "_acpmux/status")
        _ = await model.respond(to: .persistSession("s5"))
        #expect(model.sessionRoots().isEmpty)
    }
}
