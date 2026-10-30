import AppKit
import CmuxNextBridge
import CmuxNextActions
@testable import CmuxNextAgentPane
import CmuxNextPages
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// ``LinkOpener``, the one path every link and path open takes, against a real pane: by default
/// the item is made off-screen in the source pane and handed to the move into a split on its right
/// (the source keeps showing what it showed); Same Pane opens it as a tab of the source.
@MainActor struct LinkOpenerTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    /// A pane with one terminal, alone on its screen (nothing on its right).
    private static func pane() throws -> (AppServices, PaneController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.daemon.store.apply(snapshot: tree())
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: WindowState(record: record))
        return (services, pane)
    }

    @Test func byDefaultTheItemIsMadeForTheMoveToTheRightNotShownInTheSource() throws {
        let (services, pane) = try Self.pane()
        defer { pane.teardown() }
        var made: (PaneController, Bool)?
        let opened = services.linkOpener.open(from: pane) { target, placed in
            made = (target, placed != nil)
            return true
        }
        #expect(opened)
        #expect(made?.0 === pane)
        #expect(made?.1 == true, "the link opened as a tab over the source instead of moving right")
    }

    @Test func samePaneOpensATabInTheSource() throws {
        let (services, pane) = try Self.pane()
        defer { pane.teardown() }
        services.linkOpener.placement = { .samePane }
        var made: (PaneController, Bool)?
        services.linkOpener.open(from: pane) { target, placed in
            made = (target, placed != nil)
            return true
        }
        #expect(made?.0 === pane)
        #expect(made?.1 == false)
    }

    /// A refusal (a file that is gone, a pane that holds no browser) reports false, so the caller
    /// shows it instead of claiming the link opened.
    @Test func aRefusalIsReported() throws {
        let (services, pane) = try Self.pane()
        defer { pane.teardown() }
        #expect(!services.linkOpener.open(from: pane) { _, _ in false })
    }


    /// A scratch editor page root: the test lane has no built web bundles, and without a root the
    /// editor tab makes no page and so no provider (the built page wins when bundled).
    static let editorPageRoot: URL? = {
        let directory = FileManager.default.temporaryDirectory.appending(path: "editor-page-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Data("<html><body></body></html>".utf8).write(to: directory.appending(path: "index.html"))) != nil
        else { return nil }
        return directory
    }()

    @Test func aReplyLineReachesTheEditorConfigAndASecondOpenReusesTheTab() async throws {
        let root = try #require(Self.editorPageRoot, "no scratch page root")
        PageID.registerBundledRoot(root, for: FilePageKind.editor.descriptor.id)
        let (services, pane) = try Self.pane()
        defer { pane.teardown() }
        services.linkOpener.placement = { .samePane }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("line-jump-\(UUID().uuidString).txt")
        try Data("one\ntwo\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = try #require(AgentPaneReplyRequest(method: "link.openPath", params: ["path": url.path, "line": "42:7"]))
        guard case .openPath(let path, let line) = request else { Issue.record("not an open request"); return }
        #expect(services.linkOpener.openFile(URL(fileURLWithPath: path), from: pane, line: line))
        let pages = services.viewers.editorPages
        let key = try #require(pages.debugTabs.first?.key)
        _ = pages.makeView(for: key, in: nil)
        let provider = try #require(pages.provider(key))
        defer { provider.close() }
        let context = PageCallContext(page: "cmux.editor")
        let config = try await provider.call("cmux.editor.config", params: .object([:]), context: context)
        #expect(config["location"] == ["line": 42, "column": 7])
        #expect(services.linkOpener.openFile(url, from: pane, line: FileLineLocation("2-3")))
        #expect(pages.debugTabs.map(\.key) == [key])
        let next = try await provider.call("cmux.editor.config", params: .object([:]), context: context)
        #expect(next["location"] == ["line": 2, "endLine": 3])
        #expect(services.viewers.openFile(url, in: pane, userChose: false, line: FileLineLocation("1")) == nil)
        let background = try await provider.call("cmux.editor.config", params: .object([:]), context: context)
        #expect(background["location"] == nil, "automation without focus intent must not scroll an existing tab")
    }


    @Test func replyRequestsRevalidateLocationsAndRejectExtraData() {
        for value: Any in ["0", "-1", "42:0", "10000001", "42;command", 42, true] {
            #expect(AgentPaneReplyRequest(method: "link.openPath", params: ["path": "/repo/app.ts", "line": value]) == nil)
        }
        #expect(AgentPaneReplyRequest(method: "link.openPath", params: ["path": "/repo/app.ts", "line": "42", "command": "bad"]) == nil)
    }

}
