import Foundation
@testable import CmuxNextBrowser
import Testing

/// BROWSER VIDEO F2 (handoff resize-videos/BROWSER-VIDEO.md, 120 Hz films on feat 0d19fe6, 2026-11-02):
/// "Developer Tools: Open Docked" showed DevTools at the bottom, then about 13 refreshes later at the right: the page
/// was laid out at two sizes. The DevTools frontend keeps its own dock side (its `currentDockState` setting, Chrome's
/// default right) and applies it when it loads; the fork reports that as a dock-side choice and the pane moved
/// DevTools there. Chrome has one source of truth for the side (the frontend's setting); cmux now writes its own side
/// into that setting before every open, so the frontend loads with cmux's side and never moves DevTools.
@MainActor @Suite(.serialized) struct CEFDevToolsDockSideTests {
    @Test(arguments: [(BrowserDevToolsDock.bottom, Int32(2)), (.right, 3), (.left, 1), (.window, 0)])
    func everyOpenTellsTheFrontendCmuxsDockSideFirst(dock: BrowserDevToolsDock, side: Int32) throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        // What devtools.openDocked / openDockedRight / openInWindow run (DevToolsHandlers.open).
        tab.performDevTools(.dock(dock))
        tab.performDevTools(.show)
        #expect(ShimLog.calls == ["frontend-dock-side \(Rig.browser) \(side)", "command \(Rig.browser) show"],
                "the frontend's own dock side is cmux's before DevTools opens")
    }

    @Test func theToggleKeyAndConsoleAndInspectAlsoOpenOnCmuxsSide() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.bottom))
        for command in [BrowserDevToolsCommand.toggle, .console, .inspectElement] {
            ShimLog.calls = []
            tab.performDevTools(command)
            #expect(ShimLog.calls.first == "frontend-dock-side \(Rig.browser) 2", "\(command)")
        }
    }

    /// A side the person picks in the DevTools menu still moves DevTools.
    @Test func aDockSideChosenInTheFrontendStillMovesDevTools() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.bottom))
        tab.devTools = BrowserDevToolsState(isOpen: true, dock: .bottom)
        tab.devToolsController.dockSideChosen(3)
        #expect(tab.devTools.dock == .right)
    }

    // MARK: Rig

    @MainActor final class Rig {
        static let browser: Int32 = 11
        let runtime: CEFRuntime
        let root: URL

        init() throws {
            ShimLog.calls = []
            root = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-dock-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try ShimLog.library(), storage: CEFProfileStorage(root: root))
        }

        func attachedTab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: Self.browser, request: request, window: 1))
            try #require(tab.browserID == Self.browser)
            ShimLog.calls = []
            return tab
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The DevTools calls the shim got, in order (the shim is called on the main thread).
private nonisolated enum ShimLog {
    nonisolated(unsafe) static var calls: [String] = []

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let command: @convention(c) (Int32, Int32, Int32, Int32) -> Int32 = { browser, command, _, _ in
            let name = [CEFShimLibrary.DevToolsCommand.show: "show", CEFShimLibrary.DevToolsCommand.close: "close",
                        CEFShimLibrary.DevToolsCommand.console: "console", CEFShimLibrary.DevToolsCommand.inspect: "inspect"][command]
            ShimLog.calls.append("command \(browser) \(name ?? String(command))")
            return 1
        }
        let dockSide: @convention(c) (Int32, Int32) -> Int32 = { browser, side in
            ShimLog.calls.append("frontend-dock-side \(browser) \(side)")
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_command": unsafeBitCast(command, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_set_frontend_dock_side": unsafeBitCast(dockSide, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
