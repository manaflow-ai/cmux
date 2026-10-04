import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar
@testable import CmuxNextTabs

/// R68 (Lawrence 2026-10-04): a sidebar toggle in the top left that never
/// moves. It sits in the titlebar band right of the traffic lights, not in
/// the sidebar that animates; when the sidebar is hidden the tab strip
/// starts after it; every click toggles, also mid-animation.
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

    @Test func withTheSidebarHiddenTheStripStartsAfterTheToggle() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        harness.window.sidebar.model.presentation = .hidden
        await settle(harness)
        let toggle = try #require(harness.window.root.sidebarToggleFrame)
        let strip = try #require(harness.pane?.view.stripView)
        let stripFrame = strip.convert(strip.bounds, to: nil)
        #expect(stripFrame.minX + strip.computeWindowControlsInset() >= toggle.maxX)
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
}
