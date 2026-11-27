import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// BROWSER VIDEO F2 (handoff resize-videos/BROWSER-VIDEO.md, 120 Hz films on feat 0d19fe6, 2026-11-02):
/// "Developer Tools: Open Docked" showed DevTools at the bottom, then about 13 refreshes later at the right: the page
/// was laid out at two sizes. The DevTools frontend keeps its own dock side (its `currentDockState` setting, Chrome's
/// default right) and applies it when it loads; the fork reports that as a dock-side choice and the pane moved
/// DevTools there. Chrome has one source of truth for the side (the frontend's setting); cmux now writes its own side
/// into that setting when Chromium asks where DevTools goes (every way it opens), so the frontend loads with cmux's side and never moves DevTools.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFDevToolsDockSideTests {
    /// Chromium asks where DevTools goes (DEVTOOLS_WILL_OPEN) for every way it opens: cmux's commands, a panel, the
    /// page's Inspect, Chromium's own commands. cmux's side is written into the frontend's setting there, before the
    /// placement and so before the frontend exists.
    @Test(arguments: [(BrowserDevToolsDock.bottom, Int32(2)), (.right, 3), (.left, 1), (.window, 0)])
    func everyOpenTellsTheFrontendCmuxsDockSideFirst(dock: BrowserDevToolsDock, side: Int32) throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.devToolsController.layout.dock = dock  // the remembered side, without writing the runner's defaults
        rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser))
        #expect(ShimLog.calls.first == "frontend-dock-side \(Rig.browser) \(side)",
                "the frontend's own dock side is cmux's before DevTools is created: \(ShimLog.calls)")
        #expect(ShimLog.calls.contains { $0.hasPrefix("devtools-placement") }, "then the placement")
    }

    /// The page's context menu Inspect and a DevTools panel command reach Chromium without cmux's `.show`; they still
    /// open on cmux's side (the will-open event above), so a side moved by "Dock to Right" holds for them too.
    @Test func aSideChangedWhileClosedHoldsForAnInspectFromThePage() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.devToolsController.layout.dock = .bottom
        rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser))
        tab.devToolsController.layout.dock = .right  // "Dock to Right" while closed
        ShimLog.calls = []
        rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser))  // right-click > Inspect
        #expect(ShimLog.calls.first == "frontend-dock-side \(Rig.browser) 3")
    }

    /// A side the person picks in the DevTools menu still moves DevTools.
    @Test func aDockSideChosenInTheFrontendStillMovesDevTools() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.devToolsController.layout.dock = .bottom
        tab.devTools = BrowserDevToolsState(isOpen: true, dock: .bottom)
        tab.devToolsController.dockSideChosen(3)
        #expect(tab.devTools.dock == .right)
    }

    @Test func forkSidesRoundTrip() {
        for dock in [BrowserDevToolsDock.window, .left, .bottom, .right] {
            #expect(CEFDevToolsController.dock(forkSide: Int(CEFDevToolsController.forkSide(of: dock))) == dock)
        }
    }

    // MARK: Rig

    @MainActor final class Rig {
        static let browser: Int32 = 11
        let runtime: CEFRuntime
        let root: URL
        /// The pane's window: DevTools docks only in a tab shown in a window (`CEFDevToolsController.willOpen`).
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)

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
            tab.container.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView?.addSubview(tab.container)
            ShimLog.calls = []
            return tab
        }

        func close() {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            // Closed, not only emptied: a window never closed is left open (`.closesItsWindows`).
            window.closeAfterTest()
            try? FileManager.default.removeItem(at: root)
            // The runtime is `unowned` in its tabs and hosts, and a tab shown in a window outlives the test's locals
            // (its views, the window): ending the runtime first crashed the run at teardown on the fleet ("read an
            // unowned reference ... already destroyed"). Each rig lives to the end of the test process.
            Self.kept.append(self)
        }

        /// Rigs kept alive (see `close`).
        static var kept: [Rig] = []
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
        let placement: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> Void = { browser, _, _, _, _, _ in
            ShimLog.calls.append("devtools-placement \(browser)")
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
            case "cmux_shim_devtools_set_placement": unsafeBitCast(placement, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
