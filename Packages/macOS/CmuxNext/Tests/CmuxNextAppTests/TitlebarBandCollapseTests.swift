import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar
@testable import CmuxNextTabs

/// cx-uxdr (Lawrence 2026-10-08): "when sidebar hidden, these buttons must
/// have 0 width (animated) so the only thing visible is traffic lights".
/// The toolbar band (sidebar toggle, Back, Forward) follows the sidebar's
/// on-screen width: full while the sidebar shows, 0 wide and clear while it
/// is hidden, and in between while the sidebar's width animates (one
/// animation driver, so the strip under it slides with no jump). The
/// traffic lights never move.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct TitlebarBandCollapseTests {
    private func settle(_ harness: ViewChangePermissionTests.Harness) async {
        for _ in 0..<10 { await Task.yield() }
        harness.window.window?.contentView?.layoutSubtreeIfNeeded()
    }

    @Test func hidingTheSidebarCollapsesTheBandAndShowingRestoresIt() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        await settle(harness)
        let root = harness.window.root
        let band = root.toolbarBand
        let window = try #require(root.window)
        let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
        let full = band.frame
        #expect(full.width == TitlebarToolbarBand.width, "the band is full width while the sidebar shows")
        #expect(band.alphaValue == 1)

        harness.window.sidebar.model.presentation = .hidden
        try await ViewChangePermissionTests.waitUntil("the band collapsed") {
            root.layoutSubtreeIfNeeded()
            return band.frame.width == 0
        }
        #expect(band.alphaValue == 0, "a hidden sidebar leaves only the traffic lights")
        #expect((root.sidebarToggleFrame?.width ?? 0) == 0, "the toggle has 0 width")
        #expect((root.historyButtonFrame(.back)?.width ?? 0) == 0, "Back has 0 width")
        #expect((root.historyButtonFrame(.forward)?.width ?? 0) == 0, "Forward has 0 width")
        #expect(root.titlebarAccessoryFrame.maxX <= lights.maxX + 0.5, "nothing after the traffic lights holds space")
        #expect(WindowTitlebar.trafficLightsFrame(in: window) == lights, "the traffic lights keep their place")

        // The strip under the top row starts its tabs right after the traffic lights.
        let strip = try #require(harness.pane?.view.stripView)
        try await ViewChangePermissionTests.waitUntil("the pane reached the window edge") {
            root.layoutSubtreeIfNeeded()
            return strip.convert(strip.bounds, to: nil).minX < lights.maxX
        }
        strip.layoutSubtreeIfNeeded()
        let firstTab = strip.convert(strip.bounds, to: nil).minX + strip.metrics.stripHorizontalPadding + strip.computeWindowControlsInset()
        #expect(firstTab <= lights.maxX + Metrics.space3 + 0.5, "the first tab starts right after the traffic lights (\(firstTab), lights end \(lights.maxX))")
        #expect(firstTab < full.maxX, "it moved into the band's old place")
        #expect(firstTab >= lights.maxX, "and stays clear of the traffic lights")

        harness.window.sidebar.model.presentation = .shown
        try await ViewChangePermissionTests.waitUntil("the band came back") {
            root.layoutSubtreeIfNeeded()
            return band.frame.width == full.width
        }
        #expect(band.frame == full, "the band comes back to its place")
        #expect(band.alphaValue == 1)
        #expect(WindowTitlebar.trafficLightsFrame(in: window) == lights)
    }

    /// One driver: every frame of the sidebar's width animation places the
    /// band, so half a sidebar is a band part way collapsed, never a jump.
    @Test func theBandFollowsTheSidebarsOnScreenWidth() throws {
        let design = DesignSettings.shared
        let saved = design.animationSpeed
        defer { design.animationSpeed = saved }
        design.animationSpeed = .off
        let model = SidebarModel()
        let sidebar = SidebarContainerView(model: model)
        let root = WindowRootView(sidebar: sidebar, reduceTransparency: { false }, applyWindowBlur: { _, _ in })
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.layoutSubtreeIfNeeded()
        let full = root.toolbarBand.frame.width
        #expect(full == TitlebarToolbarBand.width)

        sidebar.widthConstraint.constant = model.width / 2
        root.layoutSubtreeIfNeeded()
        let half = root.toolbarBand.frame.width
        #expect(half > 0 && half < full, "half a sidebar, a band part way collapsed (\(half) of \(full))")
        #expect(root.toolbarBand.alphaValue > 0 && root.toolbarBand.alphaValue < 1)
        for button in Self.buttons(root) {
            #expect(!button.isHiddenOrHasHiddenAncestor, "a part way band keeps its buttons in the key view loop")
        }

        sidebar.widthConstraint.constant = 0
        root.layoutSubtreeIfNeeded()
        #expect(root.toolbarBand.frame.width == 0)
        #expect(root.toolbarBand.alphaValue == 0)
        // Collapsed, the 0-width buttons leave the key view loop and the
        // accessibility tree (hidden views take neither keyboard nor
        // VoiceOver focus); the View menu, palette and shortcut remain.
        for button in Self.buttons(root) {
            #expect(button.isHiddenOrHasHiddenAncestor, "a collapsed band's buttons take no keyboard or VoiceOver focus")
            #expect(!button.canBecomeKeyView)
        }

        sidebar.widthConstraint.constant = model.width
        root.layoutSubtreeIfNeeded()
        #expect(root.toolbarBand.frame.width == full)
        #expect(root.toolbarBand.alphaValue == 1)
        for button in Self.buttons(root) {
            #expect(!button.isHiddenOrHasHiddenAncestor, "the grown band's buttons come back")
        }
    }

    private static func buttons(_ root: WindowRootView) -> [NSButton] {
        [root.toolbarBand.sidebarToggle, root.toolbarBand.backButton, root.toolbarBand.forwardButton]
    }
}
