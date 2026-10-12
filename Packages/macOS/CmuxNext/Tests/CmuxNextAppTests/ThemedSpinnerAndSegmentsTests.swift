import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextPalette
@testable import CmuxNextRemoteView
@testable import CmuxNextSidebar
import Testing

/// Theme sweep 3, batch C: the palette's loading spinner, a sidebar notice's spinner and a remote
/// pane's connecting card drew AppKit's `NSProgressIndicator`, whose spokes are the appearance's
/// gray whatever the room's theme, and the certificate viewer's General / Details control drew the
/// system's selected segment. In a purple room the spinners are the app's status indicator in the
/// scope's loading ink (`Palette.textSecondary`) and the selected segment is the theme's selection.
@MainActor @Suite(.serialized) struct ThemedSpinnerAndSegmentsTests {
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

    @Test func theCertificateViewersSelectedSegmentIsTheThemeSelection() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let window = CertificateViewerWindow(chain: [], site: PageInfoSite(url: URL(string: "https://example.com"), kind: .internalPage),
                                             failure: nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        scope.adopt(window)
        let content = try #require(window.contentView)
        let tabs = try #require(Self.all(NSSegmentedControl.self, in: content).first)
        let bezel = try #require(tabs.selectedSegmentBezelColor, "the selected segment has a theme color, not the system's")
        #expect(ThemedOverlayColorsTests.same(bezel, scope.perform { Palette.selectionFill }), "\(bezel)")
        // Still the stock control (its keys and VoiceOver): two segments, the first selected.
        #expect(tabs.segmentCount == 2 && tabs.selectedSegment == 0)
    }

    // MARK: Helpers

    private static func expectThemedSpinner(in root: NSView, _ scope: ThemeScope) throws {
        #expect(all(NSProgressIndicator.self, in: root).isEmpty, "no AppKit spinner: it draws the appearance's gray")
        let spinner = try #require(all(StatusIndicatorView.self, in: root).first { !$0.isHidden }, "a visible themed spinner")
        #expect(spinner.state == .busy)
        #expect(spinner.accessibilityRole() == .progressIndicator, "VoiceOver still hears a busy indicator")
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
