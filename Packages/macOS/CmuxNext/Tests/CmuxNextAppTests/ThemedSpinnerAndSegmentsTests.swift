import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextPalette
@testable import CmuxNextRemoteView
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Theme sweep 3, batch C: the palette's loading spinner, a sidebar notice's spinner and a remote
/// pane's connecting card drew AppKit's `NSProgressIndicator`, whose spokes are the appearance's
/// gray whatever the room's theme, and the certificate viewer's General / Details control drew the
/// system's selected segment. In a purple room the spinners are the app's status indicator in the
/// scope's loading ink (`Palette.textSecondary`) and the selected segment is the theme's selection.
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

    @Test func theCertificateViewersSelectedSegmentIsTheThemeSelection() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let window = CertificateViewerWindow(chain: [], site: PageInfoSite(url: URL(string: "https://example.com"), kind: .internalPage),
                                             failure: nil, activeLook: nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        scope.adopt(window)
        let content = try #require(window.contentView)
        let tabs = try #require(Self.all(NSSegmentedControl.self, in: content).first)
        let bezel = try #require(tabs.selectedSegmentBezelColor, "the selected segment has a theme color, not the system's")
        // The theme's selection fill made opaque on the window background (and kept legible).
        let tokens = scope.tokens
        let fill = tokens.chip(tokens.selectionFill.composited(over: tokens.windowBackground.withAlpha(1))).fill
        #expect(ThemedOverlayColorsTests.same(bezel, fill.nsColor), "\(bezel)")
        // Still the stock control (its keys and VoiceOver): two segments, the first selected.
        #expect(tabs.segmentCount == 2 && tabs.selectedSegment == 0)
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

    /// Review of #19844: a selected segment's label must read on its fill in a light and a dark theme.
    @Test func theSelectedSegmentsLabelReadsOnItsFill() throws {
        let light = ThemeScope(level: .room)
        light.setOverride(ThemeSpec("Segments Light"), input: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1F2328)),
                          animated: false)
        for scope in [light, try ThemedOverlayColorsTests.purpleRoom()] {
            let window = CertificateViewerWindow(chain: [], site: PageInfoSite(url: URL(string: "https://example.com"), kind: .internalPage),
                                                 failure: nil, activeLook: nil)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            scope.adopt(window)
            let content = try #require(window.contentView)
            let tabs = try #require(Self.all(NSSegmentedControl.self, in: content).first)
            let fill = try #require(tabs.selectedSegmentBezelColor?.usingColorSpace(.sRGB))
            #expect(fill.alphaComponent > 0.99, "an opaque fill, so the label's contrast is the fill's")
            let selector = NSSelectorFromString("selectedLabelInk")
            let ink = tabs.responds(to: selector) ? tabs.value(forKey: "selectedLabelInk") as? NSColor : nil
            let label = try #require(ink?.usingColorSpace(.sRGB), "the selected label has a theme ink")
            #expect(Self.contrast(label, fill) >= 4.5, "label \(label) on \(fill)")
        }
    }

    /// The selected label is drawn in `selectedLabelInk` (read from the control's own drawing),
    /// and a disabled control's label dims as AppKit's does instead of keeping the full ink.
    @Test func theSelectedSegmentsLabelDrawsInItsInkAndDimsWhenDisabled() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let window = CertificateViewerWindow(chain: [], site: PageInfoSite(url: URL(string: "https://example.com"), kind: .internalPage),
                                             failure: nil, activeLook: nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        scope.adopt(window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let tabs = try #require(Self.all(ThemedSegmentedControl.self, in: content).first)
        #expect(tabs.bounds.width > 0 && tabs.bounds.height > 0)
        let ink = try #require(tabs.selectedLabelInk?.usingColorSpace(.sRGB))

        let drawn = try #require(Self.nearest(ink, in: tabs, segment: 0), "the control draws")
        #expect(drawn < 0.12, "some label pixel is the ink (nearest is \(drawn) off)")

        tabs.isEnabled = false
        let dimmed = try #require(Self.nearest(ink, in: tabs, segment: 0), "the disabled control draws")
        #expect(dimmed >= 0.12, "a disabled label dims: no pixel is the full ink (nearest is \(dimmed) off)")
    }

    // MARK: Helpers

    /// How close the closest opaque pixel in `segment`'s share of the control comes to `color`
    /// (0 for an exact match), read from the control's own drawing; infinity when nothing there is
    /// opaque (AppKit draws a disabled control translucent); nil when the control can't draw.
    private static func nearest(_ color: NSColor, in control: NSSegmentedControl, segment: Int) -> Double? {
        let bounds = control.bounds
        guard let rep = control.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        control.cacheDisplay(in: bounds, to: rep)
        let width = CGFloat(rep.pixelsWide) / CGFloat(control.segmentCount)
        let x0 = Int(width * CGFloat(segment)), x1 = Int(width * CGFloat(segment + 1))
        var best = Double.infinity
        for y in 0..<rep.pixelsHigh {
            for x in x0..<x1 {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.99 else { continue }
                best = min(best, distance(pixel, color))
            }
        }
        return best
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> Double {
        Double(max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                   abs(a.blueComponent - b.blueComponent)))
    }

    /// WCAG contrast of two opaque sRGB colors.
    private static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func channel(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func luminance(_ c: NSColor) -> Double {
            0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

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
