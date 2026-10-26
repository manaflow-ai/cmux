import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

@MainActor struct FilePageRestoredLineTests {
    /// A scratch editor page root: the test lane has no built web bundles, and without a root the
    /// editor tab makes no page and so no provider (the built page wins when bundled).
    static let editorPageRoot: URL? = {
        let directory = FileManager.default.temporaryDirectory.appending(path: "editor-page-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Data("<html><body></body></html>".utf8).write(to: directory.appending(path: "index.html"))) != nil
        else { return nil }
        return directory
    }()

    @Test(arguments: [false, true])
    func anUnshownRestoredTabKeepsItsLineThroughMaterialization(focus: Bool) async throws {
        _ = NSApplication.shared
        let root = try #require(Self.editorPageRoot, "no scratch page root")
        PageID.registerBundledRoot(root, for: FilePageKind.editor.descriptor.id)
        let services = AppServices(environment: AppEnvironment.current([:]))
        let file = URL(fileURLWithPath: "/private/tmp/restored-line-\(UUID().uuidString).txt")
        try Data("one\ntwo\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var restored = TabSnapshot(surface: 2, kind: .conversation, title: file.lastPathComponent)
        // The app writes a tab's route from the resolved path (`/private/tmp` reads as `/tmp`).
        let route = file.standardizedFileURL.resolvingSymlinksInPath().path
        restored.conversation = ConversationTabRef(page: "editor", route: route)
        let snapshot = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1), restored])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [snapshot])
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let tab = try #require(services.daemon.store.tab(surface: 2))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w","workspace_key":"w"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: WindowState(record: record))
        defer { pane.teardown() }
        let files = services.viewers.editorPages
        services.pages.register(files)
        #expect(services.pages.storeKey(of: tab.id) == nil)
        let key = files.open(file, in: pane, focus: focus, userChose: false, line: FileLineLocation("42:7"))
        #expect(model.tabs.count == 2, "reuse the restored tab instead of opening another")
        _ = try #require(services.pages.view(forStoreTab: tab, in: services.daemon.store, local: true, window: nil))
        let providerKey = try #require(services.pages.storeKey(of: tab.id))
        #expect(key == providerKey)
        #expect(files.debugTabs.map(\.key) == [providerKey], "no orphan state under the store tab id")
        let provider = try #require(files.provider(providerKey))
        defer { provider.close() }
        let config = try await provider.call("cmux.editor.config", params: .object([:]), context: PageCallContext(page: "cmux.editor"))
        #expect(config["path"] == .string(route))
        #expect(config["location"] == ["line": 42, "column": 7])
    }
}
