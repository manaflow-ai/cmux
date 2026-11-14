import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
@testable import CmuxNextRemoteView
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Theme sweep 3, batch C: the palette's loading spinner, a sidebar notice's spinner and a remote
/// pane's connecting card drew AppKit's `NSProgressIndicator`, whose spokes are the appearance's
/// gray whatever the room's theme. In a purple room the spinners are the app's status indicator in
/// the scope's loading ink (`Palette.textSecondary`). (The certificate viewer's segment cases left
/// with the native viewer: it is a React page now, webviews/src/browser-chrome/page-info.)
@MainActor @Suite(.serialized, .closesItsWindows) struct ThemedSpinnerAndSegmentsTests {
    @Test func thePaletteLoadingSpinnerDrawsTheTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let bar = PaletteSearchBar(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
        scope.root(bar)
        bar.update(query: "", placeholder: "Search", chips: [], rootTitle: "Commands", style: .token, keywordHint: nil,
                   isLoading: true)
        try Self.expectThemedSpinner(in: bar, scope)
    }

    @Test func aSidebarNoticeSpinnerDrawsTheTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        scope.root(card)
        card.configure(SidebarNoticeCard(id: "import", title: "Importing", progress: .indeterminate))
        try Self.expectThemedSpinner(in: card, scope)
    }

    @Test func aRemoteConnectingCardSpinnerDrawsTheTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let card = RemoteStateCard(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
        scope.root(card)
        card.configure(overlay: .connecting, host: "studio", colors: scope.perform { RemotePaneColors.resolved() })
        try Self.expectThemedSpinner(in: card, scope)
    }

    /// Review of #19844: the palette fills its panel before ordering it in, so its spinner moved to a
    /// window that was not yet visible and stayed still once the panel showed. A chrome spinner
    /// follows its own window's occlusion and spins once the window is visible.
    @Test func aSpinnerInstalledBeforeItsWindowShowsFollowsItsWindow() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 44), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let bar = PaletteSearchBar(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
        let content = try #require(window.contentView)
        scope.root(content)
        content.addSubview(bar)
        bar.update(query: "", placeholder: "Search", chips: [], rootTitle: "Commands", style: .token, keywordHint: nil,
                   isLoading: true)
        let spinner = try #require(Self.all(StatusIndicatorView.self, in: bar).first { !$0.isHidden })
        let center = NotificationCenter()
        spinner.notificationCenter = center

        window.orderFrontRegardless()
        let visible = window.occlusionState.contains(.visible)
        // Start from the opposite state, so the check holds on a host whose windows never report
        // visible (headless CI) as well as on one where they do.
        spinner.isWindowVisible = !visible
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(spinner.isWindowVisible == visible, "the spinner follows its window's occlusion (visible: \(visible))")
        let config = StatusIndicatorAppearance.shared.config
        if visible, config.animatesLoops {
            // The configured loading glyph, the same one tabs and rows draw (synced spinners, 2026-10-20).
            let busy = StatusIndicatorPlan.make(.busy, style: config.style(hint: nil), animates: true,
                                                set: config.iconSet, isStatic: config.isStatic)
            #expect(spinner.indicator.runningAnimation == busy.animation, "the spinner moves once the window shows")
        }
    }

    // MARK: Helpers

    private static func expectThemedSpinner(in root: NSView, _ scope: ThemeScope) throws {
        #expect(all(NSProgressIndicator.self, in: root).isEmpty, "no AppKit spinner: it draws the appearance's gray")
        let spinner = try #require(all(StatusIndicatorView.self, in: root).first { !$0.isHidden }, "a visible themed spinner")
        #expect(spinner.state == .busy)
        #expect(spinner.accessibilityRole() == .busyIndicator, "VoiceOver hears a busy indicator, as for AppKit's spinner")
        spinner.updateLayer()
        let loading = try #require(spinner.indicator.colors.flatMap { NSColor(cgColor: $0.loading) }, "the spinner has theme colors")
        let ink = scope.perform { Palette.textSecondary }
        #expect(ThemedOverlayColorsTests.same(loading, ink), "spinner \(loading) vs \(ink)")
    }

    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for subview in view.subviews { found += all(type, in: subview) }
        return found
    }
}
