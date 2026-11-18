import AppKit
@testable import CmuxNextBrowser
import CmuxNextBrowserCore
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import Testing

/// Lucas 2026-11-16: match Helium's toolbar pixel for pixel at Compact (Helium's size): the reload glyph draws 14 px tall,
/// the omnibar's search glyph 12 px and its text's capitals 10 px (with the text smoothing's edge), and every other
/// density scales those by its factor over Compact's 0.9, within a pixel (each box snaps to whole pixels).
@MainActor @Suite(.serialized, .closesItsWindows) struct HeliumToolbarSizeTests {
    @Test(arguments: DensityPreset.allCases)
    func reloadSearchAndTextMatchHeliumScaled(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        let reload = try #require(try SidebarRowGlyphOpticalSizeTests.inkBox(chrome.reloadButton))
        let icon = try #require(chrome.addressBar.chip.subviews.compactMap { $0 as? NSImageView }.first { !$0.isHidden })
        let search = try #require(try SidebarRowGlyphOpticalSizeTests.inkBox(icon))
        let font = try #require(chrome.addressBar.field.font)
        let scale = CGFloat(preset.omnibarScaleFactor) / 0.9 // Default's toolbar row is Compact's
        let caps = font.capHeight + 0.31 // what the eye measures: font smoothing grows the capitals about 0.31 pt
        let tolerance: CGFloat = preset.omnibarScaleFactor == DensityPreset.compact.scaleFactor ? 0.5 : 1
        #expect(abs(reload.height - 14 * scale) <= tolerance, "\(preset): the reload glyph is \(reload.height) tall, want \(14 * scale)")
        let searchWant: CGFloat = preset == .cozy ? 12 * 18 / 17 : 12 * scale // Default's 18 pt box (Lucas 2026-11-18)
        #expect(abs(search.height - searchWant) <= tolerance, "\(preset): the search glyph is \(search.height) tall, want \(searchWant)")
        let capsWant: CGFloat = preset == .cozy ? 11 : 10 * scale // Default's are a point taller (Lucas 2026-11-17)
        #expect(abs(caps - capsWant) <= 0.25, "\(preset): the URL's capitals are \(caps) tall, want \(capsWant)")
    }

    /// Lucas 2026-11-17: the URL's H at Compact is exactly 10 pt, 20 rows at 2x, with no lit row above it, and at Default
    /// 11 pt, 22 rows ("for default our font size has to be 1px taller in height"). macOS font smoothing grows each glyph
    /// edge by about 0.31 pt, so the font's own capitals are that much under; at 14.01 pt a 21st row lit 39% above the
    /// H and it read taller than 10 pt.
    @Test(arguments: [(DensityPreset.compact, 20), (.cozy, 22)])
    func theURLsCapitalsFillWholeRowsWithSmoothing(preset: DensityPreset, rows: Int) throws {
        let font = NSFont.systemFont(ofSize: OmnibarMetrics(tokens: preset.tokens).fontSize)
        let side = 48
        let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.scaleBy(x: 2, y: 2)
        ctx.setShouldSmoothFonts(true)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "H", attributes: [.font: font, .foregroundColor: NSColor.white]))
        ctx.textPosition = CGPoint(x: 3, y: 2)
        CTLineDraw(line, ctx)
        let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        func lit(_ x: Int, _ y: Int) -> Double { Double(pixels[(y * side + x) * 4]) / 255 }
        // The left stem: the column with the most ink.
        let stem = try #require((0..<side / 2).max { a, b in (0..<side).reduce(0) { $0 + lit(a, $1) } < (0..<side).reduce(0) { $0 + lit(b, $1) } })
        let column = (0..<side).map { lit(stem, $0) }
        let full = column.filter { $0 > 0.97 }.count
        let first = try #require(column.firstIndex { $0 > 0.03 })
        #expect(full == rows, "\(preset): the H fills \(full) rows at 2x, want \(rows)")
        #expect(column[first] > 0.97, "\(preset): a row lit \(column[first]) above the H's capitals")
    }
}
