import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The native New Tab page's spare (Lawrence 2026-10-30: "prepare one Swift New Tab page in advance
/// and reuse it on Cmd+T, the same way the web page does"). Cmd-T cold showed the page on its 4th
/// display frame (51 ms p50, cmux19-perf): the pane made its view on the next presentation frame and
/// SwiftUI laid it out after that. With a spare, Cmd-T shows the prepared, laid-out view in the
/// same main-actor turn.
@MainActor @Suite(.serialized)
struct NativeNewTabSpareTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "native-ws"), name: "native", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "native-ws"), index: 0)])
        return tree
    }

    private static func host(in view: NSView) -> NativeNewTabHostingView? {
        if let host = view as? NativeNewTabHostingView { return host }
        return view.subviews.lazy.compactMap { host(in: $0) }.first
    }

    @Test func cmdTShowsThePreparedPageInTheSameTurn() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let directory = FileManager.default.temporaryDirectory.appending(path: "native-spare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"tabs":{"nativeNewTabPage":true}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings

        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["native-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        defer {
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let pane = try #require(content.panes.values.first)
        let pool = services.newTabSpares
        pool.retarget(window)
        pool.warmNative()
        let spare = try #require(pool.nativeSpare, "the setting is on, but no native spare was prepared")
        #expect(spare.fieldView != nil, "the spare was not laid out before Cmd-T")

        // Cmd-T: no layout pass, no frame between the open and the checks.
        let key = try #require(NewTabPage.openNative(in: pane, reusingShown: false))
        #expect(pane.currentTabKey == key, """
            the page waits for a later frame to show (selected \(pane.stripModel.selectedID?.rawValue ?? "-"), \
            alive \(pane.selectedContentIsAlive), suspended \(pane.isSuspended))
            """)
        #expect(Self.host(in: pane.view) === spare, "Cmd-T built a new page instead of adopting the spare")
        #expect(spare.fieldView != nil)
        #expect(pool.nativeSpare == nil, "the adopted spare is still parked")

        // With no spare left, a second Cmd-T makes its page cold, and the pool prepares the next spare.
        let second = try #require(NewTabPage.openNative(in: pane, reusingShown: false))
        for _ in 0..<300 where pane.currentTabKey != second { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pane.currentTabKey == second, "the cold page never showed")
        pool.warmNative()
        #expect(pool.nativeSpare != nil && pool.nativeSpare !== spare, "no new spare after the adoption")
    }

    /// The spare is laid out at the pane size it was made at, and the parked spare follows a pane resize
    /// only after ``NewTabSparePool/fitSettle``. A Cmd-T right after a resize adopts it at the old size:
    /// the first frame's layout pass must still show it at the pane's new size with its field inside it
    /// (the page's wrapper sizes it by constraints in that pass). Before that pass it is the old size,
    /// which no frame draws.
    @Test func aSpareAdoptedRightAfterAPaneResizeFitsTheNewSize() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let directory = FileManager.default.temporaryDirectory.appending(path: "native-spare-resize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"tabs":{"nativeNewTabPage":true}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings

        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["native-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        defer {
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let pane = try #require(content.panes.values.first)
        let pool = services.newTabSpares
        pool.retarget(window)
        pool.warmNative()
        let spare = try #require(pool.nativeSpare, "no native spare was prepared")
        let madeWidth = spare.frame.width

        // The window narrows: the pane is 400 pt narrower, and Cmd-T comes in the same turn.
        var frame = window.frame
        frame.size.width -= 400
        window.setFrame(frame, display: false)
        content.contentView.layoutSubtreeIfNeeded()
        let size = NewTabSparePool.newTabContentSize(in: pane)
        try #require(size.width < madeWidth - 300, "the pane did not narrow (\(madeWidth) -> \(size.width))")
        _ = try #require(NewTabPage.openNative(in: pane, reusingShown: false))
        try #require(Self.host(in: pane.view) === spare, "Cmd-T did not adopt the spare")

        // The layout pass the first frame runs: the page fits the pane and its field is inside it.
        window.contentView?.layoutSubtreeIfNeeded()
        let shown = pane.view.contentHost.bounds.size
        #expect(abs(spare.frame.width - shown.width) < 1, "the first frame shows the page at \(spare.frame.width) pt in a \(shown.width) pt pane")
        let field = try #require(spare.fieldView)
        let fieldFrame = spare.convert(field.bounds, from: field)
        #expect(fieldFrame.minX >= -0.5 && fieldFrame.maxX <= spare.bounds.maxX + 0.5,
                "the field is laid out for another width: \(fieldFrame.minX)...\(fieldFrame.maxX) in a \(spare.bounds.width) pt page")
    }
}
