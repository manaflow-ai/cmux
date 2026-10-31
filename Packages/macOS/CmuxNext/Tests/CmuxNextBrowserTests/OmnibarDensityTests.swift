import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The omnibar follows density and `browser.omnibar.height` / `fontSize`
/// (https://github.com/manaflow-ai/cmux/issues/28734): Standard (the `compact` preset, the default)
/// stays today's 28 pt bar with 14 pt text, Comfortable is Chrome's roomier 34 pt bar with 15 pt
/// text, an override beats density and is clamped, and at every density and override the bar's
/// text, chip, star, toolbar buttons and suggestion rows stay inside their bounds.
@MainActor @Suite(.serialized) struct OmnibarDensityTests {
    // MARK: Tokens

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
            chrome.addressBar.dismissRows()
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
    static let cases: [(preset: DensityPreset, height: Double?, fontSize: Double?)] =
        DensityPreset.allCases.map { ($0, nil, nil) } + [(.compact, 20, 24), (.comfortable, 56, 10), (.ultraCompact, nil, 24)]

    /// Long URL, "Not secure" chip, star, toolbar buttons and suggestion rows: each stays inside the
    /// bar or the toolbar row, the field is tall enough for its text, and nothing overlaps.
    @Test(arguments: cases.indices)
    func nothingClipsOrOverlaps(index: Int) throws {
        let (preset, height, fontSize) = Self.cases[index]
        OmnibarGlassAppearance.shared.applySize(height: height, fontSize: fontSize)
        defer { OmnibarGlassAppearance.shared.applySize(height: nil, fontSize: nil) }
        try DensityTokens.$scoped.withValue(preset.tokens) {
            let view = Chrome()
            defer { view.tearDown() }
            let bar = view.chrome.addressBar
            let long = "https://example.com/" + String(repeating: "a-very-long-path-segment/", count: 40) + "?q=" + String(repeating: "x", count: 200)
            bar.update(url: URL(string: long), security: .insecure)
            bar.starButton.state = .off
            view.chrome.layoutSubtreeIfNeeded()
            bar.layoutSubtreeIfNeeded()
            let expected = OmnibarMetrics.current
            let label = "\(preset) height \(String(describing: height)) font \(String(describing: fontSize))"

            let barRect = view.rect(bar), toolbar = view.rect(view.chrome.toolbar), page = view.rect(view.chrome.contentContainer)
            #expect(barRect.height == expected.barHeight, "\(label): the bar is \(barRect.height) pt")
            #expect(Self.inside(barRect, toolbar), "\(label): the bar \(barRect) runs out of the toolbar \(toolbar)")
            #expect(page.maxY <= toolbar.minY + 0.5, "\(label): the page overlaps the toolbar")
            #expect(bar.field.font?.pointSize == expected.fontSize, "\(label)")

            let field = view.rect(bar.field), chip = view.rect(bar.chip), star = view.rect(bar.starButton)
            #expect(Self.inside(field, barRect), "\(label): the field \(field) leaves the bar \(barRect)")
            let font = try #require(bar.field.font)
            #expect(field.height >= ceil(font.ascender - font.descender), "\(label): the field \(field.height) pt cuts its \(font.pointSize) pt text")
            #expect(Self.inside(chip, barRect), "\(label): the chip \(chip) leaves the bar")
            #expect(chip.maxX <= field.minX + 0.5, "\(label): the chip overlaps the URL")
            if !bar.starButton.isHidden {
                #expect(Self.inside(star, barRect), "\(label): the star \(star) leaves the bar")
                #expect(field.maxX <= star.minX + 0.5, "\(label): the URL runs under the star")
            }
            for button in [view.chrome.backButton, view.chrome.reloadButton] {
                let frame = view.rect(button)
                #expect(frame.width == expected.buttonSize && frame.height == expected.buttonSize, "\(label): a button is \(frame.size)")
                #expect(Self.inside(frame, toolbar), "\(label): a toolbar button \(frame) leaves the toolbar \(toolbar)")
                #expect(frame.maxX <= barRect.minX + 0.5, "\(label): a button overlaps the bar")
            }

            // Editing: focus keeps the same geometry.
            bar.focus()
            view.chrome.layoutSubtreeIfNeeded()
            #expect(view.rect(bar) == barRect, "\(label): editing moves the bar")

            // The suggestion card: each row is the bar's height, its text and glyph inside it.
            let suggestion = BrowserSuggestion(kind: .history, title: "A suggestion title " + String(repeating: "long ", count: 30),
                                               detail: "detail", url: URL(string: "https://example.com/")!, score: 1)
            bar.showRows([suggestion, suggestion], highlighted: 0)
            let card = try #require(bar.debugCard)
            #expect(card.isFlushUnderBar, "\(label)")
            for row in bar.panel.rowViews {
                row.layoutSubtreeIfNeeded()
                #expect(row.bounds.height == expected.barHeight, "\(label): a row is \(row.bounds.height) pt")
                #expect(Self.inside(row.label.frame, row.bounds), "\(label): a row's text \(row.label.frame) leaves \(row.bounds)")
                #expect(Self.inside(row.icon.frame, row.bounds), "\(label): a row's glyph leaves the row")
            }
            let rows = bar.panel.rowViews.map { $0.convert($0.bounds, to: nil) }
            for (upper, lower) in zip(rows, rows.dropFirst()) {
                #expect(lower.maxY <= upper.minY + 0.5, "\(label): suggestion rows overlap")
            }
        }
    }

    /// A change of `browser.omnibar.*` sizes applies to an open chrome live, and back.
    @Test func sizeChangesApplyLive() async {
        let view = Chrome()
        defer { view.tearDown() }
        let bar = view.chrome.addressBar
        #expect(view.rect(bar).height == 28)
        OmnibarGlassAppearance.shared.applySize(height: 40, fontSize: 18)
        defer { OmnibarGlassAppearance.shared.applySize(height: nil, fontSize: nil) }
        await Self.settle()
        view.chrome.layoutSubtreeIfNeeded()
        #expect(view.rect(bar).height == 40)
        #expect(bar.field.font?.pointSize == 18)
        #expect(view.chrome.currentToolbarHeight == OmnibarStyle.toolbarHeight(scale: view.window.backingScaleFactor))
        #expect(view.rect(view.chrome.toolbar).height == view.chrome.currentToolbarHeight)

        OmnibarGlassAppearance.shared.applySize(height: nil, fontSize: nil)
        await Self.settle()
        view.chrome.layoutSubtreeIfNeeded()
        #expect(view.rect(bar).height == 28)
        #expect(bar.field.font?.pointSize == TypeScale.field)
    }

    /// Lets the binding's observation re-apply (it re-arms on the next main-actor turn).
    private static func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }
}
