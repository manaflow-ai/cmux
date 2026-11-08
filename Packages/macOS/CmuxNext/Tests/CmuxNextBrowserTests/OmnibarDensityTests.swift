import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The omnibar follows density and `browser.omnibar.height` / `fontSize`
/// (https://github.com/manaflow-ai/cmux/issues/28734): Standard (the `compact` preset, the default)
/// stays today's 28 pt bar with 14 pt text, Comfortable is Chrome's roomier 34 pt bar with 15 pt
/// text, an override beats density and is clamped, and at every density and override the bar's
/// text, chip, star, toolbar buttons and suggestion rows stay inside their bounds.
@MainActor @Suite(.serialized, .closesItsWindows) struct OmnibarDensityTests {
    // MARK: Tokens

    /// Fractional sizes round to whole points, so the bar stays on the pixel grid.
    @Test func overridesRoundToWholePoints() {
        let metrics = OmnibarMetrics(tokens: .compact, height: 30.4, fontSize: 15.6)
        #expect(metrics.barHeight == 30 && metrics.fontSize == 16)
    }

    /// The glyph a suggestion row and the chip draw (`iconRowSize`, about 1.2 times the point size)
    /// keeps 2 pt inside the chip even in the shortest bar.
    @Test func theChipGlyphFitsTheShortestBar() {
        for height in stride(from: 20.0, through: 34, by: 1) {
            let metrics = OmnibarMetrics(tokens: .compact, height: height, fontSize: 10)
            // `CGFloat.iconRowSize`: 1.2 times the point size, never under 12.
            let glyph = max(12, (1.2 * metrics.iconPointSize).rounded())
            let chip = metrics.barHeight - 4
            #expect(glyph <= chip - 4, "a \(glyph) pt glyph in the \(chip) pt chip of a \(metrics.barHeight) pt bar")
        }
    }

    @Test func standardIsTodaysBarExactly() {
        let standard = OmnibarMetrics(tokens: DensityPreset.compact.tokens)
        #expect(standard == OmnibarMetrics(tokens: .compact))
        #expect(standard.barHeight == 28 && standard.buttonSize == 28)
        #expect(standard.fontSize == TypeScale.field)
        #expect(standard.iconPointSize == 13 && standard.toolbarIconSize == 20 && standard.trailingIconSize == 18)
    }

    @Test func comfortableIsChromesRoomierBar() {
        let comfortable = OmnibarMetrics(tokens: DensityPreset.comfortable.tokens)
        #expect(comfortable.barHeight == 34 && comfortable.buttonSize == 34)
        #expect(comfortable.fontSize == TypeScale.title)
        #expect(comfortable.iconPointSize == 15 && comfortable.toolbarIconSize == 22 && comfortable.trailingIconSize == 20)
    }

    /// Ultra-compact is tighter than today, Spacious roomier, and every size grows with the density.
    @Test func everyDensitySitsOnOneLine() {
        let all = DensityPreset.allCases.map { OmnibarMetrics(tokens: $0.tokens) }
        #expect(all.first!.barHeight < 28, "Ultra-compact is \(all.first!.barHeight) pt")
        for (denser, roomier) in zip(all, all.dropFirst()) {
            #expect(denser.barHeight <= roomier.barHeight && denser.fontSize <= roomier.fontSize && denser.buttonSize <= roomier.buttonSize)
        }
        for metrics in all {
            #expect(metrics.barHeight >= OmnibarMetrics.minimumBarHeight(fontSize: metrics.fontSize), "\(metrics)")
        }
    }

    /// A custom density's `fontSize` scales the bar's text with the rest of the chrome.
    @Test func aCustomDensityFontSizeScalesTheBarText() {
        let large = DensityTokens(id: "large", name: "Large", fontSize: 14)
        #expect(OmnibarMetrics(tokens: large).fontSize > TypeScale.field)
    }

    // MARK: Overrides

    @Test func currentTextFollowsInterfaceSizeWhilePureMetricsKeepTheirReferenceSize() {
        let design = DesignSettings.shared
        let previous = design.overrides[.chromeFontSize]
        defer { design.setOverride(.chromeFontSize, previous) }
        OmnibarGlassAppearance.$scoped.withValue(OmnibarGlassAppearance()) {
            DensityTokens.$scoped.withValue(.compact) {
                design.setOverride(.chromeFontSize, nil)
                let original = OmnibarMetrics.current
                design.setOverride(.chromeFontSize, 16)
                let enlarged = OmnibarMetrics.current
                #expect(enlarged.fontSize == original.fontSize * Typography.userScale)
                #expect(enlarged.barHeight >= OmnibarMetrics.minimumBarHeight(fontSize: enlarged.fontSize))
                #expect(OmnibarMetrics(tokens: .compact).fontSize == original.fontSize)
                design.setOverride(.chromeFontSize, nil)
                #expect(OmnibarMetrics.current == original)
            }
        }
    }

    @Test func overridesBeatDensity() {
        let metrics = OmnibarMetrics(tokens: DensityPreset.comfortable.tokens, height: 30, fontSize: 13)
        #expect(metrics.barHeight == 30)
        #expect(metrics.fontSize == 13)
        // The buttons keep the density's size.
        #expect(metrics.buttonSize == 34)
    }

    @Test func overridesAreClampedIntoTheirRanges() {
        let huge = OmnibarMetrics(tokens: .compact, height: 500, fontSize: 99)
        #expect(huge.barHeight == CGFloat(OmnibarMetrics.heightRange.upperBound))
        #expect(huge.fontSize == CGFloat(OmnibarMetrics.fontSizeRange.upperBound))
        let tiny = OmnibarMetrics(tokens: .compact, height: 1, fontSize: 1)
        #expect(tiny.fontSize == CGFloat(OmnibarMetrics.fontSizeRange.lowerBound))
        #expect(tiny.barHeight >= CGFloat(OmnibarMetrics.heightRange.lowerBound))
        let notANumber = OmnibarMetrics(tokens: .compact, height: .nan, fontSize: .infinity)
        #expect(notANumber == OmnibarMetrics(tokens: .compact))
    }

    /// A short bar with large text grows to fit the text instead of cutting it.
    @Test func theBarGrowsToFitItsText() {
        let metrics = OmnibarMetrics(tokens: .compact, height: 20, fontSize: 24)
        #expect(metrics.barHeight == OmnibarMetrics.minimumBarHeight(fontSize: 24))
        #expect(metrics.iconPointSize <= metrics.barHeight - 8)
        #expect(metrics.trailingIconSize <= metrics.barHeight - 6)
    }

    // MARK: Layout

    private struct Chrome {
        let window: NSWindow
        let chrome: BrowserChromeView
        let page: WebKitTab

        init(width: CGFloat = 900) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            chrome = BrowserChromeView(tab: page)
            chrome.frame = window.contentLayoutRect
            window.contentView = chrome
            window.orderFrontRegardless()
            chrome.layoutSubtreeIfNeeded()
        }

        func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

        func tearDown() {
            chrome.closePopupPanels()
            window.orderOut(nil)
            window.close()
            page.close()
        }
    }

    private static func inside(_ inner: NSRect, _ outer: NSRect) -> Bool {
        inner.minX >= outer.minX - 0.5 && inner.maxX <= outer.maxX + 0.5 && inner.minY >= outer.minY - 0.5 && inner.maxY <= outer.maxY + 0.5
    }

    /// The cases the layout test runs: every built-in density, and overrides that push the text
    /// against the bar (large text in a short bar, a tall bar with small text).
    nonisolated static let cases: [(preset: DensityPreset, height: Double?, fontSize: Double?)] =
        DensityPreset.allCases.map { ($0, nil, nil) }
            + [(.compact, 20, 24), (.compact, 20, 10), (.comfortable, 56, 10), (.ultraCompact, nil, 24), (.comfortable, 30.4, 15.6)]

    /// The toolbar page lays the row out with the metrics the row pushes; the row holds them, the
    /// bar sits inside it and the page area starts below it. (The page's own layout of field,
    /// chip, star and buttons is tested in browser-chrome/toolbar.)
    @Test(arguments: cases.indices)
    func theRowHoldsTheBarItPushes(index: Int) throws {
        let (preset, height, fontSize) = Self.cases[index]
        // A scoped appearance: the app-wide `shared` (and every other suite) is never touched.
        let overrides = OmnibarGlassAppearance()
        overrides.applySize(height: height, fontSize: fontSize)
        try OmnibarGlassAppearance.$scoped.withValue(overrides) { try DensityTokens.$scoped.withValue(preset.tokens) {
            let view = Chrome()
            defer { view.tearDown() }
            let expected = OmnibarMetrics.current
            let label = "\(preset) height \(String(describing: height)) font \(String(describing: fontSize))"
            let metrics = try #require(view.chrome.addressBar.wireState()["metrics"] as? [String: Any])
            #expect(metrics["bar"] as? CGFloat == expected.barHeight, "\(label)")
            #expect(metrics["fontSize"] as? CGFloat == expected.fontSize, "\(label)")
            #expect(metrics["button"] as? CGFloat == expected.buttonSize, "\(label)")
            let barTop = try #require(metrics["barTop"] as? CGFloat)
            let toolbar = view.rect(view.chrome.toolbar), page = view.rect(view.chrome.contentContainer)
            #expect(barTop >= 0 && barTop + expected.barHeight <= toolbar.height + 0.5, "\(label): the bar leaves the \(toolbar.height) pt row")
            #expect(expected.buttonSize <= toolbar.height, "\(label): a button is taller than the row")
            #expect(page.maxY <= toolbar.minY + 0.5, "\(label): the page overlaps the toolbar")
        } }
    }

    /// A change of `browser.omnibar.*` sizes applies to an open chrome live, and back.
    /// The scoped appearance reaches the views' re-apply loops (they re-arm in tasks started in
    /// the scope), so the change below is seen only by this test's chrome.
    @Test func sizeChangesApplyLive() async {
        let overrides = OmnibarGlassAppearance()
        await OmnibarGlassAppearance.$scoped.withValue(overrides) { await DensityTokens.$scoped.withValue(.compact) {
            await Self.liveChange(overrides)
        } }
    }

    private static func liveChange(_ overrides: OmnibarGlassAppearance) async {
        let view = Chrome()
        defer { view.tearDown() }
        let bar = view.chrome.addressBar
        func pushed(_ key: String) -> CGFloat? { (bar.wireState()["metrics"] as? [String: Any])?[key] as? CGFloat }
        #expect(pushed("bar") == 28)
        overrides.applySize(height: 40, fontSize: 18)
        await Self.settle()
        view.chrome.layoutSubtreeIfNeeded()
        #expect(pushed("bar") == 40)
        #expect(pushed("fontSize") == 18)
        #expect(view.chrome.currentToolbarHeight == ToolbarRowMetrics.toolbarHeight(scale: view.window.backingScaleFactor))
        #expect(view.rect(view.chrome.toolbar).height == view.chrome.currentToolbarHeight)

        overrides.applySize(height: nil, fontSize: nil)
        await Self.settle()
        view.chrome.layoutSubtreeIfNeeded()
        #expect(pushed("bar") == 28)
        #expect(pushed("fontSize") == TypeScale.field)
    }

    /// Lets the binding's observation re-apply (it re-arms on the next main-actor turn).
    private static func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }
}
