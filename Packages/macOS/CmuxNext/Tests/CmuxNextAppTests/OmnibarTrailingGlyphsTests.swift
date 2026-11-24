import AppKit
@testable import CmuxNextBrowser
import CmuxNextBrowserCore
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lucas 2026-11-18, measured on screen: "the extensions icon on compact should be 2px taller. its currently at 14px",
/// "the star/favourite icon should be 12px height. it is currently 10px", "pixel perfect please"; "the icons for
/// star/favourite and extensions and : from compact should === to default"; then "maybe the star needs 1px thicker line
/// thickness? it still looks a bit small compared to helium", Default's star at Chrome's size, and the ⋮ as Helium and
/// Chrome draw it; then "for compact revert the line thickness back to what it was. then for compact and for default
/// make the star 2px bigger ... 2px in ehight": 14 pt at Compact, 17 at Default, both Chrome's own outline; then "for
/// compact, leave it as it is. for default decrease by 1px" and "ensure that its correctly laigned in the omnibar
/// (vertically aligned)": 16 pt at Default, its ink centered in its plate and the bar; then "for compact it should
/// acutally be 0.5px smaller": 13.5 pt at Compact. Measured from the drawn pixels at 2x as he measures: the rows from the first lit one to the last.
/// Helium and Chrome were measured the same way from their windows (2026-11-18): Helium's star 24 rows with 207 px² of
/// ink, Chrome's star 30 rows, both apps' puzzle 32 rows and ⋮ 24 rows by 6 columns.
@MainActor @Suite(.serialized, .closesItsWindows) struct OmnibarTrailingGlyphsTests {
    /// Each pixel's alpha at 2x, rows top to bottom.
    static func alpha(_ view: NSView) throws -> [[Double]] {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return (0..<rep.pixelsHigh).map { y in (0..<rep.pixelsWide).map { Double(rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) } }
    }

    /// The drawn glyph: its lit rows' profile (each row's strongest pixel, first lit row to last), its lit column count
    /// and its ink area in pixels (each pixel's share of the strongest).
    struct Ink: Equatable {
        var rows: [Double]
        var columns: Int
        var area: Double
    }

    static func ink(_ view: NSView) throws -> Ink {
        let pixels = try alpha(view)
        let peak = max(pixels.flatMap { $0 }.max() ?? 1, 0.001)
        func lit(_ profile: [Double]) -> ClosedRange<Int>? {
            let on = profile.indices.filter { profile[$0] > 0.02 }
            guard let first = on.first, let last = on.last else { return nil }
            return first...last
        }
        let rowProfile = pixels.map { $0.max() ?? 0 }
        let columnProfile = (0..<(pixels.first?.count ?? 0)).map { x in pixels.map { $0[x] }.max() ?? 0 }
        let rows = lit(rowProfile).map { Array(rowProfile[$0]) } ?? []
        let area = pixels.flatMap { $0 }.reduce(0) { $0 + $1 / peak }
        return Ink(rows: rows, columns: lit(columnProfile)?.count ?? 0, area: (area * 10).rounded() / 10)
    }

    struct Glyphs: Equatable {
        var star: Ink
        var starOn: Ink
        var puzzle: Ink
        var more: Ink
    }

    static func glyphs(_ preset: DensityPreset) throws -> Glyphs {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        _ = NSApplication.shared
        let window = TwoXWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 1200, height: 500)
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        let star = chrome.addressBar.starButton
        star.isHidden = false
        star.state = .off
        chrome.layoutSubtreeIfNeeded()
        let off = try ink(star)
        star.state = .on
        chrome.layoutSubtreeIfNeeded()
        let on = try ink(star)
        let puzzle = chrome.extensionToolbar.puzzle
        if puzzle.superview == nil { chrome.addSubview(puzzle) }
        chrome.layoutSubtreeIfNeeded()
        let more = try #require(chrome.toolbarButtons.anchor(for: .overflow) as? ChromeIconButton)
        return Glyphs(star: off, starOn: on, puzzle: try ink(puzzle), more: try ink(more))
    }

    @Test func compactsStarIs13AndAHalfAndItsExtensionsPuzzle16Tall() throws {
        let compact = try Self.glyphs(.compact)
        #expect(compact.star.rows.count == 27, "the star draws \(compact.star.rows.count) rows at 2x: want 27 (13.5 pt)")
        #expect(compact.starOn.rows.count == 27, "the filled star draws \(compact.starOn.rows.count) rows at 2x: want 27 (13.5 pt)")
        #expect(compact.puzzle.rows.count == 32, "the Extensions puzzle draws \(compact.puzzle.rows.count) rows at 2x: want 32 (16 pt)")
    }

    /// Compact's star keeps Chrome's own outline: 205 px² of ink at 27 rows, every lit row whole (an outline a pixel
    /// heavier had 1.24 times the ink).
    @Test func compactsStarHasChromesOutline() throws {
        let compact = try Self.glyphs(.compact)
        #expect(abs(compact.star.area - 205) <= 205 * 0.03, "the star has \(compact.star.area) px² of ink at 2x: want Chrome's outline, 205")
        #expect((compact.star.rows.first ?? 0) > 0.15 && (compact.star.rows.last ?? 0) > 0.15,
                "the star's edge rows are \(compact.star.rows.first ?? 0) and \(compact.star.rows.last ?? 0) lit: want no faint row")
    }

    /// Default's star is Chrome's 15 pt and 1 more: 32 rows (16 pt) at 2x, Chrome's own outline (291 px² of ink).
    @Test func defaultsStarIs16() throws {
        let cozy = try Self.glyphs(.cozy)
        #expect(abs(cozy.star.area - 291) <= 291 * 0.03, "the star has \(cozy.star.area) px² of ink at 2x: want Chrome's outline, 291")
        #expect(cozy.star.rows.count == 32, "the star draws \(cozy.star.rows.count) rows at 2x: want 32 (16 pt)")
        #expect(cozy.starOn.rows.count == 32, "the filled star draws \(cozy.starOn.rows.count) rows at 2x: want 32 (16 pt)")
    }

    /// The star scales with the bar from Compact's 13.5 pt (Lucas 2026-11-18: "make sure the star scales up in comfortable
    /// and spacious proportionally too. and that its pixel perfect"): 12, 13.5, 16.5 and 18 pt at Ultra-compact, Compact,
    /// Comfortable and Spacious, Default's own 16. Lit rows at 2x, the outermost ones whole except Ultra-compact's and
    /// Default's faint top row (no half-point side draws 24 or 32 whole rows).
    @Test(arguments: [(DensityPreset.ultraCompact, 24), (.compact, 27), (.cozy, 32), (.comfortable, 33), (.spacious, 36)])
    func theStarScalesWithTheBar(preset: DensityPreset, rows: Int) throws {
        let glyphs = try Self.glyphs(preset)
        #expect(glyphs.star.rows.count == rows, "\(preset): the star draws \(glyphs.star.rows.count) rows at 2x: want \(rows)")
        #expect(glyphs.starOn.rows.count == rows, "\(preset): the filled star draws \(glyphs.starOn.rows.count) rows: want \(rows)")
        if ![DensityPreset.ultraCompact, .cozy].contains(preset) {
            #expect((glyphs.star.rows.first ?? 0) > 0.15 && (glyphs.star.rows.last ?? 0) > 0.15, "\(preset): a faint edge row")
        }
    }

    /// The star's ink sits on the bar's middle line: its plate is centered on the bar (`theStarsPlateIsHeliums`), and
    /// inside the plate the lit rows have as many clear rows above them as below, at 2x. An odd row count cannot center
    /// on the plate's even rows: the star then sits half a pixel high, where a star's own center (below its box's
    /// middle, its point reaching further than its legs) is closest to the bar's middle.
    @Test(arguments: DensityPreset.allCases)
    func theStarsInkIsCenteredInItsPlate(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        _ = NSApplication.shared
        let window = TwoXWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 1200, height: 500)
        window.contentView = chrome
        let star = chrome.addressBar.starButton
        star.isHidden = false
        for state in [BookmarkStarState.off, .on] {
            star.state = state
            chrome.layoutSubtreeIfNeeded()
            let rows = try Self.alpha(star).map { $0.max() ?? 0 }
            let lit = rows.indices.filter { rows[$0] > 0.02 }
            let above = try #require(lit.first), below = rows.count - 1 - (try #require(lit.last))
            #expect(above == (above + below) / 2, "\(preset) \(state): \(above) clear rows above the star's ink in its plate, \(below) below")
        }
    }

    /// The toolbar's ⋮ is Helium's and Chrome's: 24 rows (12 pt) by 6 columns at 2x, at Compact and Default (the pane's
    /// tab bar has no ⋮ of its own, #53356).
    @Test(arguments: [DensityPreset.compact, .cozy])
    func theMoreDrawsChromesDots(preset: DensityPreset) throws {
        let glyphs = try Self.glyphs(preset)
        #expect(glyphs.more.rows.count == 24 && glyphs.more.columns == 6,
                "\(preset): the toolbar ⋮ is \(glyphs.more.rows.count) rows by \(glyphs.more.columns): want 24 by 6")
    }

    /// Default's Extensions puzzle and ⋮ draw Compact's pixels, row for row.
    @Test func defaultsPuzzleAndMoreAreCompacts() throws {
        let compact = try Self.glyphs(.compact), cozy = try Self.glyphs(.cozy)
        #expect(cozy.puzzle == compact.puzzle, "the puzzle: Default \(cozy.puzzle.rows.count) rows, Compact \(compact.puzzle.rows.count)")
        #expect(cozy.more == compact.more, "the ⋮: Default \(cozy.more.rows.count) rows, Compact \(compact.more.rows.count)")
    }
    /// The star's hover plate is Helium's (Lucas 2026-11-18: "we should show a more promiment hover, and bigger container.
    /// this is how helium does it match it 1:1"; measured from his screenshot at 2x): a square the bar's height less 2 pt
    /// on each side, as far from the bar's trailing edge as from its top, rounded a quarter of its side with circular
    /// corners. 24 pt with 6 pt corners on Compact's 28 pt bar. Default's is 28 pt on its 34 pt bar, Compact's padding
    /// around its 16 pt star (Lucas 2026-11-18: "they seem to be quite big? ... don't have an insane amount of padding").
    @Test(arguments: [(DensityPreset.compact, CGFloat(24)), (.cozy, 28)])
    func theStarsPlateIsHeliums(preset: DensityPreset, side: CGFloat) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        _ = NSApplication.shared
        let window = TwoXWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 1200, height: 500)
        window.contentView = chrome
        let bar = chrome.addressBar
        bar.starButton.isHidden = false
        bar.starButton.state = .off
        chrome.layoutSubtreeIfNeeded()
        let star = bar.starButton.convert(bar.starButton.bounds, to: bar)
        #expect(star.size == CGSize(width: side, height: side), "\(preset): the plate is \(star.size): want \(side)")
        let gap = (bar.bounds.height - side) / 2
        #expect(abs(bar.bounds.maxX - star.maxX - gap) < 0.01, "\(preset): \(bar.bounds.maxX - star.maxX) pt from the bar's trailing edge: want \(gap)")
        #expect(abs(star.midY - bar.bounds.midY) < 0.01, "\(preset): the plate's middle is \(star.midY - bar.bounds.midY) pt off the bar's")
        #expect(bar.starButton.layer?.cornerRadius == side / 4, "\(preset): corner \(bar.starButton.layer?.cornerRadius ?? 0): want \(side / 4)")
        #expect(bar.starButton.layer?.cornerCurve == .circular, "\(preset): Helium's corners are circular")
    }
    /// Over Helium's dark bar (68 of 255) the plate's fill composites to Helium's hovered plate, 92.
    @Test func theStarsHoverFillIsHeliums() {
        let fill = OmnibarStyle.starHoverFill(isDark: true)
        let bar: CGFloat = 68 / 255
        let plate = (fill.whiteComponent * fill.alphaComponent + bar * (1 - fill.alphaComponent)) * 255
        #expect(abs(plate - 92) < 0.5, "the hovered plate is \(plate) of 255 over Helium's bar: want 92")
    }
    /// The toolbar buttons' boxes are a tab tall at every density, as the tab bar's ⋮ above them (Lawrence 2026-11-23: "all
    /// buttons need to have same derived size, which is same height as the tabs"; before, Compact's padding around each
    /// glyph, Lucas 2026-11-18), centered on the bar to the 2x pixel: Spacious's 36 pt box on its 37.5 pt bar sits a
    /// quarter point (half a pixel) off, the nearest the grid allows.
    @Test(arguments: DensityPreset.allCases)
    func theToolbarButtonsAreATabTall(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        _ = NSApplication.shared
        let window = TwoXWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 1200, height: 500)
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        let barMid = chrome.convert(chrome.addressBar.bounds, from: chrome.addressBar).midY
        for (name, button) in [("back", chrome.backButton as NSView), ("forward", chrome.forwardButton), ("reload", chrome.reloadButton),
                               ("more", try #require(chrome.toolbarButtons.anchor(for: .overflow)))] {
            let frame = chrome.convert(button.bounds, from: button)
            #expect(frame.height == Metrics.tabHeight && frame.width == frame.height,
                    "\(preset) \(name): a \(frame.size) box, want a \(Metrics.tabHeight) pt square")
            #expect(abs(frame.midY - barMid) <= 0.25, "\(preset) \(name): \(frame.midY - barMid) pt off the bar's middle")
            #expect(frame.minY * 2 == (frame.minY * 2).rounded(), "\(preset) \(name): the box is off the pixel grid at \(frame.minY)")
        }
    }
}
