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
        let lit = rows.map { ($0 - floor) / max(top - floor, 0.001) }
        let first = try #require(lit.firstIndex { $0 > 0.05 }), last = try #require(lit.lastIndex { $0 > 0.05 })
        return CGFloat(first) / 2...CGFloat(last + 1) / 2
    }

    @Test(arguments: DensityPreset.allCases)
    func theURLsCapitalsCenterOnTheSearchGlyph(preset: DensityPreset) throws {
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
        let bar = chrome.addressBar
        bar.field.stringValue = "HHHH"
        bar.layoutSubtreeIfNeeded()
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
