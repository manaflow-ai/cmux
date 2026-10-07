import AppKit
import CmuxNextActions
import Foundation
import CmuxNextDesign
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar
@testable import CmuxNextTabs

/// R68 (Lawrence 2026-10-04): a sidebar toggle in the top left that never
/// moves. It sits in the titlebar band right of the traffic lights, not in
/// the sidebar that animates; when the sidebar is hidden the tab strip
/// starts after it; every click toggles, also mid-animation. It shows at
/// rest, open or collapsed (Leo, T3 Code ref, 2026-10-07).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct StaticSidebarToggleTests {
    private func settle(_ harness: ViewChangePermissionTests.Harness) async {
        for _ in 0..<10 { await Task.yield() }
        harness.window.window?.contentView?.layoutSubtreeIfNeeded()
    }

    @Test func theToggleKeepsItsFrameShownHiddenAndMidAnimation() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        await settle(harness)
        let root = harness.window.root
        let shown = try #require(root.sidebarToggleFrame)
        harness.window.sidebar.model.toggle()
        root.layoutSubtreeIfNeeded()
        let midAnimation = try #require(root.sidebarToggleFrame)
        await settle(harness)
        let hidden = try #require(root.sidebarToggleFrame)
        #expect(shown == midAnimation && shown == hidden)
        // Snapshots of both states for review (cmux-lawrence-2 artifacts).
        if let dir = ProcessInfo.processInfo.environment["NX_ARTIFACTS"], let window = root.window {
            try window.renderSnapshot()?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/toggle-hidden.png"))
            harness.window.sidebar.model.toggle()
            await settle(harness)
            try window.renderSnapshot()?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/toggle-shown.png"))
        }
        // It is right of the traffic lights, in the top row.
        if let window = root.window, let lights = WindowTitlebar.trafficLightsFrame(in: window) {
            #expect(shown.minX >= lights.maxX && shown.midY > window.contentLayoutRect.maxY - Metrics.tabStripHeight)
        }
    }

    @Test func tenRapidClicksToggleTenTimes() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        await settle(harness)
        let model = harness.window.sidebar.model
        let start = model.presentation
        var toggles = 0
        for _ in 0..<10 {
            let before = model.presentation
            harness.window.root.pressSidebarToggle()
            if model.presentation != before { toggles += 1 }
        }
        #expect(toggles == 10)
        #expect(model.presentation == start)
    }

    /// Leo (T3 Code ref, 2026-10-07), replacing nxdog41's corner collapse:
    /// with the sidebar hidden the traffic lights and the toggle stay shown
    /// at rest, the toggle keeps its frame, and the strip starts its tabs
    /// after it, so a click back and forth hits one fixed target. The
    /// sidebar state reaches the window root through an observation, so the
    /// test waits for it instead of for a fixed number of turns. The hide is
    /// the animated one a click makes; in a window with no screen (the
    /// aws-m4pro fleet Macs) Motion applies it at once
    /// (`Motion.canAnimate(in:)`), so it settles on every host.
    @Test func withTheSidebarHiddenTheStripStartsAfterTheToggle() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        await settle(harness)
        let root = harness.window.root
        let shown = try #require(root.sidebarToggleFrame)
        harness.window.sidebar.model.presentation = .hidden
        try await ViewChangePermissionTests.waitUntil { root.sidebarHidden }
        try #require(root.sidebarHidden, "the sidebar state reached the window root")
        await settle(harness)
        let toggle = try #require(root.sidebarToggleFrame)
        #expect(toggle == shown, "the toggle keeps its frame")
        let strip = try #require(harness.pane?.view.stripView)
        // The pane moves to the window edge as the sidebar's hide finishes.
        try await ViewChangePermissionTests.waitUntil {
            root.layoutSubtreeIfNeeded()
            return strip.convert(strip.bounds, to: nil).minX < toggle.minX
        }
        let stripFrame = strip.convert(strip.bounds, to: nil)
        #expect(stripFrame.minX + strip.computeWindowControlsInset() >= toggle.maxX, "the first tab starts after the toggle")
        #expect(root.toolbarBand.sidebarToggle.alphaValue == 1, "the toggle shows at rest")
        for button in root.trafficLightButtons { #expect(button.alphaValue == 1, "the traffic lights show at rest") }
    }

    /// Open, the toggle shows a collapse-left glyph; collapsed, the sidebar
    /// glyph (Leo, T3 Code ref, 2026-10-07).
    @Test func theToggleGlyphFollowsTheSidebar() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        await settle(harness)
        let root = harness.window.root
        let toggle = root.toolbarBand.sidebarToggle
        #expect(toggle.symbol == "rectangle.lefthalf.inset.filled.arrow.left")
        harness.window.sidebar.model.presentation = .hidden
        try await ViewChangePermissionTests.waitUntil { root.sidebarHidden }
        #expect(toggle.symbol == "sidebar.left")
        harness.window.sidebar.model.presentation = .shown
        try await ViewChangePermissionTests.waitUntil { !root.sidebarHidden }
        #expect(toggle.symbol == "rectangle.lefthalf.inset.filled.arrow.left")
        for symbol in ["sidebar.left", "rectangle.lefthalf.inset.filled.arrow.left"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol) is a system symbol")
        }
    }

    @Test func theToggleNamesItsActionAndShortcut() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        await settle(harness)
        let button = try #require(harness.window.root.sidebarToggleButton)
        #expect(button.accessibilityLabel()?.isEmpty == false)
        if let shortcut = harness.services.registry.shortcutDisplay(for: "toggleSidebar") {
            #expect(button.toolTip?.contains(shortcut) == true)
        }
    }

    /// The tooltip follows a rebind of Toggle Sidebar (it read the key once).
    @Test func theTooltipFollowsARebind() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        await settle(harness)
        let registry = harness.services.registry
        registry.setShortcutOverride(Shortcut("y", modifiers: [.command, .control]), for: "toggleSidebar")
        defer { registry.removeShortcutOverride(for: "toggleSidebar") }
        for _ in 0..<20 { await Task.yield() }
        let display = try #require(registry.shortcutDisplay(for: "toggleSidebar"))
        #expect(harness.window.root.sidebarToggleButton?.toolTip?.contains(display) == true)
    }
}
