import AppKit
@testable import CmuxNextBrowser
import CmuxNextBrowserCore
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Lucas 2026-11-17: the URL's capitals and the search glyph center on one line, the bar's middle. Measured from
/// the drawn pixels at 2x: the field drew its baseline at its top plus `firstBaselineOffsetFromTop`, and the shift
/// that centers the capitals had assumed the font's unrounded ascender, 0.29 pt lower at Compact. The H then sat a
/// pixel above the search glyph at Compact, Default and Comfortable.
@MainActor @Suite(.serialized, .closesItsWindows) struct OmnibarCapitalsCenterTests {
    /// The rows (from the top, in points at 2x) where `view` draws ink in `column` (a pixel column; nil: any column).
    static func inkRows(_ view: NSView, in bar: NSView, column: ((NSBitmapImageRep) -> Int)? = nil) throws -> ClosedRange<CGFloat> {
        let lit = try inkProfile(view, in: bar, column: column)
        let first = try #require(lit.firstIndex { $0 > 0.05 }), last = try #require(lit.lastIndex { $0 > 0.05 })
        return CGFloat(first) / 2...CGFloat(last + 1) / 2
    }

    /// Each pixel row's ink (0 to 1, from the top, at 2x) where `view` draws in `column` (a pixel column; nil: any column).
    static func inkProfile(_ view: NSView, in bar: NSView, column: ((NSBitmapImageRep) -> Int)? = nil) throws -> [Double] {
        let size = bar.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        bar.cacheDisplay(in: bar.bounds, to: rep)
        let frame = bar.convert(view.bounds, from: view)
        let xs = column.map { [$0(rep)] } ?? Array(Int(frame.minX * 2)..<Int(frame.maxX * 2))
        func ink(_ x: Int, _ y: Int) -> Double {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            return Double(c.alphaComponent) * Double(c.redComponent + c.greenComponent + c.blueComponent) / 3
        }
        let rows = (0..<rep.pixelsHigh).map { y in xs.map { ink($0, y) }.max() ?? 0 }
        let floor = rows.min() ?? 0, top = rows.max() ?? 1
        return rows.map { ($0 - floor) / max(top - floor, 0.001) }
    }

    /// Each pixel row's most opaque pixel (from the top, at 2x) in `view` drawn alone.
    static func alphaProfile(_ view: NSView) throws -> [Double] {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return (0..<rep.pixelsHigh).map { y in (0..<rep.pixelsWide).map { Double(rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) }.max() ?? 0 }
    }

    /// Lucas 2026-11-17: "maybe make the search icon 1px taller too for default", and Compact's stays exactly as it is
    /// ("its perfect"). Measured from the search glyph's own pixels at 2x (an empty tab; a loaded page draws its
    /// page-info glyph): Default's ink is 2 rows (1 pt) taller than Compact's, and Compact's glyph keeps its 17 pt box.
    /// Then Lucas 2026-11-18: "the search glyph on default density can be 0.5px shorter in height". The box snaps to half
    /// points: an 18 pt box draws 1.5 rows over Compact's (0.36 pt under the 18.5 box), the nearest to 0.5 pt under it.
    @Test func defaultsSearchGlyphIsALittleTaller() throws {
        func ink(_ preset: DensityPreset) throws -> (rows: Double, side: CGFloat) {
            let design = DesignSettings.shared
            let saved = design.densityTokens
            defer { design.densityTokens = saved }
            design.densityTokens = preset.tokens
            _ = NSApplication.shared
            let window = TwoXWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: nil))
            let chrome = BrowserChromeView(tab: tab)
            chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
            window.contentView = chrome
            chrome.layoutSubtreeIfNeeded()
            let icon = try #require(chrome.addressBar.chip.subviews.compactMap { $0 as? NSImageView }.first { !$0.isHidden })
            let alpha = try Self.alphaProfile(icon), top = alpha.max() ?? 1
            // Each row's share of the glyph's full ink (its tint is not opaque): the glyph's height in rows.
            let rows = alpha.reduce(0) { $0 + $1 / max(top, 0.001) }
            print("SEARCH|\(preset.rawValue)|side \(icon.frame.height)|rows \(rows)|\(alpha.map { Int($0 / max(top, 0.001) * 100) })")
            return (rows, icon.frame.height)
        }
        let compact = try ink(.compact), cozy = try ink(.cozy)
        #expect(compact.side == 17, "Compact's search glyph keeps its 17 pt box: \(compact.side)")
        #expect(cozy.side == 18, "Default's search glyph has an 18 pt box: \(cozy.side)")
        #expect(abs(cozy.rows - compact.rows - 1.5) <= 0.25,
                "Default's search glyph is \(cozy.rows) rows at 2x, Compact's \(compact.rows): want 1.5 rows more")
    }

    @Test(arguments: DensityPreset.allCases)
    func theURLsCapitalsCenterOnTheSearchGlyph(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        _ = NSApplication.shared
        let window = TwoXWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        let bar = chrome.addressBar
        bar.field.stringValue = "HHHH"
        bar.layoutSubtreeIfNeeded()
        // A secure page's chip shows at rest (OmnibarCutsTests).
        #expect(bar.chip.alphaValue == 1 && !bar.chip.isHidden, "\(preset): a secure page's chip is clear at rest")
        let icon = try #require(bar.chip.subviews.compactMap { $0 as? NSImageView }.first { !$0.isHidden })
        let glyph = try Self.inkRows(icon, in: bar)
        // The first H's stem: the field's column with the most ink.
        let fieldX = Int(bar.convert(bar.field.bounds, from: bar.field).minX * 2)
        let capitals = try Self.inkRows(bar.field, in: bar) { rep in
            (fieldX..<fieldX + 30).max { a, b in
                func total(_ x: Int) -> Double { (0..<rep.pixelsHigh).reduce(0) { sum, y in
                    let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    return sum + Double(c?.alphaComponent ?? 0) * Double((c?.redComponent ?? 0) + (c?.greenComponent ?? 0) + (c?.blueComponent ?? 0))
                } }
                return total(a) < total(b)
            } ?? fieldX
        }
        let glyphCenter = (glyph.lowerBound + glyph.upperBound) / 2, capsCenter = (capitals.lowerBound + capitals.upperBound) / 2
        #expect(abs(capsCenter - glyphCenter) <= 0.25,
                "\(preset): the H spans \(capitals) and centers at \(capsCenter); the search glyph spans \(glyph) and centers at \(glyphCenter)")
        #expect(abs(glyphCenter - bar.bounds.height / 2) <= 0.25, "\(preset): the search glyph centers on the bar's middle")
    }
}
