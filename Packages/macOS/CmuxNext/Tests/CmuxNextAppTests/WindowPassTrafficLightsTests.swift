import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// AppKit runs the window's layout pass (`-[NSWindow layoutIfNeeded]`) before every display, also when no view needs
/// layout: every key typed into a text field displays the window. `ShellWindow` ran its after-pass work each time, and
/// most of it was the traffic lights' placement (`TrafficLightsLine.apply`, the top row's line from the pane chrome
/// metrics, read twice): 63 of 78 samples of that work in a `sample` of 300 keys in a 3,000-character Home draft, in
/// which the window's pass laid out a view twice (cmux21, macOS 27, fleet Debug build; a1250, 2026-11-20). A pass that
/// lays out no view moves no button: AppKit's own titlebar tiling is a layout, and a move outside any pass reaches the
/// lights' owner (`TrafficLightsOwner`) in its own call. A real `ShellWindow` with the app's root view.
@MainActor @Suite(.serialized, .closesItsWindows) struct WindowPassTrafficLightsTests {
    private func window() -> (ShellWindow, WindowRootView) {
        _ = NSApplication.shared
        // The window tells a pass that laid out a view from one that did not by the guard's layout count (installed at
        // launch in every build).
        LayoutPassGuard.shared.install()
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        for _ in 0..<2 {
            root.needsLayout = true
            window.layoutIfNeeded()
        }
        return (window, root)
    }

    private func withTopRow(_ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let saved = (design.titlebar, design.tabBarPosition)
        defer { (design.titlebar, design.tabBarPosition) = saved }
        design.titlebar = .minimal
        design.tabBarPosition = .top
        try body()
    }

    /// Window passes that lay out no view (a key's display) place the lights no more.
    @Test func aPassThatLaysOutNoViewPlacesNoLights() throws {
        try withTopRow {
            let (window, _) = window()
            defer { window.close() }
            let owner = TrafficLightsOwner.of(window)
            let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
            let before = owner.placements
            let calls = LayoutPassGuard.shared.viewLayoutCalls
            for _ in 0..<20 { window.layoutIfNeeded() }
            try #require(LayoutPassGuard.shared.viewLayoutCalls == calls, "the passes laid out a view: not the case under test")
            #expect(owner.placements == before, "20 window passes that laid out no view placed the lights \(owner.placements - before) times")
            #expect(WindowTitlebar.trafficLightsFrame(in: window) == lights, "the lights moved")
        }
    }

    /// A pass that lays out a view still puts the lights on the top row's line.
    @Test func aPassThatLaysOutAViewKeepsTheLightsOnTheLine() throws {
        try withTopRow {
            let (window, root) = window()
            defer { window.close() }
            let owner = TrafficLightsOwner.of(window)
            let before = owner.placements
            window.setFrame(window.frame.insetBy(dx: -60, dy: -40), display: false)
            root.needsLayout = true
            window.layoutIfNeeded()
            #expect(owner.placements > before, "a pass that laid out the root placed no lights")
            let line = try #require(WindowTitlebar.topRowLine(in: window))
            let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
            #expect(abs(window.frame.height - lights.midY - line.centerY) <= 0.5, "the lights left the top row's line")
        }
    }
}
