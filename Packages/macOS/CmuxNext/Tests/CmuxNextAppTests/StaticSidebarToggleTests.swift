import AppKit
import CmuxNextActions
import Foundation
import CmuxNextDesign
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar
@testable import CmuxNextTabs

/// R68 (Lawrence 2026-10-04): a sidebar toggle in the top left, in the
/// titlebar band right of the traffic lights, not in the sidebar that
/// animates; every click toggles, also mid-animation. With the sidebar
/// hidden the band collapses to 0 width so only the traffic lights show
/// (cx-uxdr, Lawrence 2026-10-08; `TitlebarBandCollapseTests`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct StaticSidebarToggleTests {
    private func settle(_ harness: ViewChangePermissionTests.Harness) async {
        for _ in 0..<10 { await Task.yield() }
        harness.window.window?.contentView?.layoutSubtreeIfNeeded()
    }

    @Test func theToggleSitsAfterTheTrafficLightsAndHasZeroWidthWhenHidden() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        await settle(harness)
        let root = harness.window.root
        let shown = try #require(root.sidebarToggleFrame)
        #expect(shown.width == TitlebarBandButton.side)
        // It is right of the traffic lights, in the top row.
        if let window = root.window, let lights = WindowTitlebar.trafficLightsFrame(in: window) {
            #expect(shown.minX >= lights.maxX && shown.midY > window.contentLayoutRect.maxY - Metrics.tabStripHeight)
        }
        harness.window.sidebar.model.toggle()
        try await ViewChangePermissionTests.waitUntil {
            root.layoutSubtreeIfNeeded()
            return (root.sidebarToggleFrame?.width ?? 0) == 0
        }
        // Snapshots of both states for review (cmux-lawrence-2 artifacts).
        if let dir = ProcessInfo.processInfo.environment["NX_ARTIFACTS"], let window = root.window {
            try window.renderSnapshot()?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/toggle-hidden.png"))
        }
        harness.window.sidebar.model.toggle()
        try await ViewChangePermissionTests.waitUntil {
            root.layoutSubtreeIfNeeded()
            return root.sidebarToggleFrame == shown
        }
        if let dir = ProcessInfo.processInfo.environment["NX_ARTIFACTS"], let window = root.window {
            try window.renderSnapshot()?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/toggle-shown.png"))
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
