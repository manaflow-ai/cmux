import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Foundation
import Testing

/// #48512: the footer's "Search", "Run Command", "Actions" and the ↩ and ⇥ keycaps did not share
/// one center line. Each label's line box was centered, which puts the capitals of a 13 pt label
/// lower than an 11 pt one's, and each keycap centered its glyph's line box, which puts ↩ and ⇥
/// under the middle of their caps. Draws the real footer at 2x, in light and dark, at every density
/// and at the default, 16 pt and 20 pt text sizes, and measures each one's ink: every label's
/// letters, every keycap's glyph and every keycap's fill must center on the footer's middle.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct PaletteFooterAlignmentTests {
    /// The layout snaps to the window's pixel grid (half a point at most on a 1x screen) and the ink
    /// is read at 2x (a quarter point per edge); the line-box layout missed by up to 0.75 pt at 2x.
    private static func tolerance(_ window: NSWindow) -> CGFloat { 0.5 / max(window.backingScaleFactor, 1) + 0.25 }

    @Test func footerTextAndKeycapsShareOneCenterLine() async throws {
        _ = NSApplication.shared
        let commands = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        commands.show(.commands)
        await commands.model.settle()
        defer { commands.closeForTest() }
        #expect(commands.model.primaryTitle != nil, "the command page's footer shows its primary button")

        var windows: [NSWindow] = []
        defer { windows.forEach { $0.closeAfterTest() } }
        for preset in DensityPreset.allCases {
            for size in [nil, 16.0, 20.0] as [CGFloat?] {
                var tokens = preset.tokens
                if let size { tokens.fontSize = size }
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let label = "\(preset.tokens.name), \(size.map { "\(Int($0)) pt" } ?? "default size"), \(appearance.rawValue)"
                    try DensityTokens.$scoped.withValue(tokens) {
                        try Self.check(commands.model, appearance: appearance, label, windows: &windows)
                    }
                }
            }
        }
    }

    /// Only symbol keys center their own ink: a "," or "." keycap (⌥⌘, and ⌥⌘. switch focus, ⌘,
    /// opens Settings) keeps its glyph on the baseline, under the cap's middle, not floated into it.
    @Test func punctuationKeycapsKeepTheirBaseline() throws {
        _ = NSApplication.shared
        // One view per key: two keys after one another in one view are a chord's two strokes.
        let glyphs = try [",", ".", "↩"].map { cap in
            let keys = PaletteKeycapsView()
            keys.keycaps = [cap]
            let size = keys.intrinsicContentSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.closeAfterTest() }
            let host = NSView(frame: NSRect(origin: .zero, size: size))
            window.contentView = host
            keys.frame = host.bounds
            host.addSubview(keys)
            let ink = try Ink(host)
            let fillAlpha = ink.alpha(x: Metrics.space1 / 2, y: size.height / 2)
            // Inside the cap's hairline edge (and clear of its rounded corners), only the legend is above the fill.
            let inside = host.bounds.insetBy(dx: PaletteLayout.keycapCornerRadius, dy: 1)
            return (try #require(ink.rows(in: inside, above: fillAlpha), "\(cap) draws"), size.height / 2)
        }
        #expect(glyphs[0].0.mid < glyphs[0].1 - 1, "\",\" sits low in its cap: \(glyphs[0])")
        #expect(glyphs[1].0.mid < glyphs[1].1 - 1, "\".\" sits low in its cap: \(glyphs[1])")
        #expect(abs(glyphs[2].0.mid - glyphs[2].1) <= 0.75, "↩ (\"return\") centers in its cap: \(glyphs[2])")
    }

    /// Leo 2026-11-22: "not even properly depicting the keys". ↩ and ⇥ print as the keyboard's "return"
    /// and "tab", and a chord (New Agent Chat's ⌘J then S) draws "then" between its strokes: wider than
    /// three caps side by side.
    @Test func keycapsNameTheKeysAndSplitAChord() {
        _ = NSApplication.shared
        let keys = PaletteKeycapsView()
        #expect(keys.capWidth("↩") == keys.capWidth("return"))
        #expect(keys.capWidth("↩") > PaletteLayout.keycapSize, "\"return\" is wider than a square cap")
        keys.keycaps = ["⇧", "⌘", "P"]
        let one = keys.intrinsicContentSize.width
        #expect(one == ["⇧", "⌘", "P"].map(keys.capWidth).reduce(0, +) + Metrics.space1 * 2)
        keys.keycaps = ["⌘", "J", "S"]
        let caps = ["⌘", "J", "S"].map(keys.capWidth).reduce(0, +) + Metrics.space1 * 2
        #expect(keys.intrinsicContentSize.width > caps + Metrics.space1, "the chord's \"then\" sits between J and S")
    }

    private static func check(_ model: PaletteModel, appearance: NSAppearance.Name, _ label: String, windows: inout [NSWindow]) throws {
        let view = PaletteContentView(model: model)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: PaletteLayout.windowSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        windows.append(window)
        view.layoutSubtreeIfNeeded()

        let footer = try #require(descendants(of: view).compactMap { $0 as? PaletteFooterView }.first, "\(label)")
        footer.layoutSubtreeIfNeeded()
        let ink = try Ink(footer)
        let midY = footer.bounds.midY
        let tolerance = Self.tolerance(window)
        var measured: [String] = []

        for text in descendants(of: footer).compactMap({ $0 as? NSTextField })
        where !text.isHiddenOrHasHiddenAncestor && !text.stringValue.isEmpty {
            let font = try #require(text.font, "\(label)")
            let frame = footer.convert(text.bounds, from: text)
            let span = try #require(ink.rows(in: frame), "\(label): \"\(text.stringValue)\" draws no ink")
            // The capitals' middle is measured up from the baseline (the ink's top is an ascender, taller than the
            // capitals). A word with no descender has its baseline at its ink's bottom; one with a descender ("Open",
            // "All Scopes") has it where the field lays its first line out, the ink's bottom being the descender.
            let hasDescender = text.stringValue.contains(where: { "gjpqy,".contains($0) })
            let baseline = hasDescender ? frame.maxY - text.firstBaselineOffsetFromTop : span.min
            let capsMid = baseline + font.capHeight / 2
            #expect(abs(capsMid - midY) <= tolerance,
                    "\(label): \"\(text.stringValue)\" capitals center at \(capsMid), the footer's middle is \(midY)")
            measured.append(text.stringValue)
        }
        for keys in descendants(of: footer).compactMap({ $0 as? PaletteKeycapsView }) where !keys.isHiddenOrHasHiddenAncestor {
            let frame = footer.convert(keys.bounds, from: keys)
            let cap = try #require(ink.rows(in: frame, above: 0), "\(label): \(keys.keycaps) draws no cap")
            #expect(abs(cap.mid - midY) <= tolerance, "\(label): the \(keys.keycaps) cap centers at \(cap.mid), the footer's middle is \(midY)")
            // The fill's alpha beside the glyph (a cap is at least as wide as tall and its glyph is centered).
            let fillAlpha = ink.alpha(x: frame.minX + Metrics.space1, y: midY)
            // Inside the cap's hairline edge (and clear of its rounded corners), only the legend is above the fill.
            let glyph = try #require(ink.rows(in: frame.insetBy(dx: PaletteLayout.keycapCornerRadius, dy: 1), above: fillAlpha),
                                     "\(label): \(keys.keycaps) draws no glyph")
            #expect(abs(glyph.mid - midY) <= tolerance,
                    "\(label): the \(keys.keycaps) glyph centers at \(glyph.mid), the footer's middle is \(midY)")
            measured.append(keys.keycaps.joined())
        }
        #expect(measured.contains(PaletteStrings.actions), "\(label): measured \(measured)")
        #expect(measured.contains("↩") && measured.contains("⇥"), "\(label): measured \(measured)")
        #expect(measured.contains(model.primaryTitle ?? "-"), "\(label): measured \(measured)")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// The footer drawn alone at 2x on a clear background: only text, glyphs, keycap fills, the
    /// divider and the page icon have alpha.
    private struct Ink {
        let rep: NSBitmapImageRep
        let height: CGFloat

        init(_ footer: NSView) throws {
            let size = footer.bounds.size
            rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = size
            footer.cacheDisplay(in: footer.bounds, to: rep)
            height = size.height
        }

        func alpha(x: CGFloat, y: CGFloat) -> Int {
            var pixel = [Int](repeating: 0, count: 4)
            rep.getPixel(&pixel, atX: Int(x * 2), y: Int((height - y) * 2))
            return pixel[3]
        }

        /// The vertical extent (points, unflipped) of the ink inside `frame`: pixels whose alpha is
        /// over `above` (out of 255) by at least half the region's most, so an antialiased edge counts
        /// the same at the top and the bottom. `above` is the keycap fill's alpha when measuring its
        /// glyph, 0 for text or for the cap itself (any alpha at all).
        func rows(in frame: NSRect, above floor: Int? = nil) -> (min: CGFloat, max: CGFloat, mid: CGFloat)? {
            let x0 = max(0, Int(frame.minX * 2)), x1 = min(rep.pixelsWide, Int(frame.maxX * 2))
            let top = max(0, Int((height - frame.maxY) * 2)), bottom = min(rep.pixelsHigh, Int((height - frame.minY) * 2))
            guard x0 < x1, top < bottom else { return nil }
            var rowMax = [Int](repeating: 0, count: bottom - top)
            var pixel = [Int](repeating: 0, count: 4)
            for y in top..<bottom {
                for x in x0..<x1 {
                    rep.getPixel(&pixel, atX: x, y: y)
                    rowMax[y - top] = max(rowMax[y - top], pixel[3])
                }
            }
            let base = floor ?? 0
            let peak = rowMax.max() ?? 0
            let threshold = floor == 0 ? 1 : base + max(1, (peak - base) / 2)
            guard let first = rowMax.firstIndex(where: { $0 >= threshold }),
                  let last = rowMax.lastIndex(where: { $0 >= threshold }) else { return nil }
            // Pixel rows count down from the top; a row covers [y, y + 1).
            let maxY = height - CGFloat(top + first) / 2, minY = height - CGFloat(top + last + 1) / 2
            return (minY, maxY, (minY + maxY) / 2)
        }
    }
}
