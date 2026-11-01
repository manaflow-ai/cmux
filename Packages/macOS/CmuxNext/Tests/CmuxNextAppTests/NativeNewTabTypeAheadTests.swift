import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The native New Tab page (`tabs.nativeNewTabPage`): keys typed right after it opens, before
/// SwiftUI has made its field, go to the field in typing order. Without the window's key hold
/// (`NewTabInputCoordinator`) they reached the page's host view and were lost (the capture tour typed
/// "split" and the field stayed empty).
@MainActor @Suite(.serialized)
struct NativeNewTabTypeAheadTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "native-ws"), name: "native", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "native-ws"), index: 0)])
        return tree
    }

    private static func key(_ character: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
    }

    private static func host(in view: NSView) -> NativeNewTabHostingView? {
        if let host = view as? NativeNewTabHostingView { return host }
        return view.subviews.lazy.compactMap { host(in: $0) }.first
    }

    @Test func keysTypedBeforeTheFieldExistsLandInIt() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let directory = FileManager.default.temporaryDirectory.appending(path: "native-new-tab-\(UUID().uuidString)")
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
        let input = services.keyRouter.newTabInputCoordinator
        input.holdLimit = .seconds(600)
        input.scheduleDeadline = { _, _ in Task {} }

        // Cmd-T's open and two keys in the same main-actor turn: the field cannot exist yet.
        let key = try #require(NewTabPage.openNative(in: pane, reusingShown: false), "the setting is on, but the native page did not open")
        let typed = [try Self.key("h", keyCode: 4, in: window), try Self.key("i", keyCode: 34, in: window)]
        for event in typed where !services.keyRouter.interceptKeyDown(event, in: window) { window.sendEvent(event) }

        // The page shows and lays out: its field takes the held keys.
        var host: NativeNewTabHostingView?
        for _ in 0..<300 {
            content.contentView.layoutSubtreeIfNeeded()
            host = Self.host(in: pane.view)
            host?.layoutSubtreeIfNeeded()
            if let field = host?.fieldView as? NSTextField, field.stringValue == "hi" || (field.currentEditor()?.string ?? "") == "hi" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pane.currentTabKey == key)
        let field = try #require(host?.fieldView as? NSTextField, "the native page never showed its field")
        let text = field.currentEditor()?.string ?? field.stringValue
        #expect(text == "hi", "keys typed before the field existed were lost (field \"\(text)\", hold log \(input.log))")
        #expect(!input.isHolding(in: window), "the hold kept the keys after the field existed: \(input.log)")
    }
}
