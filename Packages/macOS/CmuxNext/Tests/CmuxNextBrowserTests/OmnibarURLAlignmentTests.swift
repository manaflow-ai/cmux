import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// The address sits flush left right after the page-info chip, as in Chrome
/// (https://github.com/manaflow-ai/cmux/issues/42273): on an http page the URL started
/// far to the right of the chip's "Not secure" label, with the label's text
/// running under it. The chip takes exactly its own width; the field takes the rest of
/// the bar and draws its text from its left edge.
@MainActor
@Suite(.closesItsWindows)
struct OmnibarURLAlignmentTests {
    private func bar(width: CGFloat, url: String, security: BrowserSecurityState) -> (AddressBarView, NSWindow) {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 60, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView!.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 10),
            bar.widthAnchor.constraint(equalToConstant: width),
            bar.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        bar.update(url: URL(string: url), security: security)
        bar.setBookmarkStar(.off)
        window.contentView!.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    /// The leftmost and rightmost opaque pixel columns of `view`'s drawing, in
    /// points from the bar's leading edge.
    private func inkSpan(_ view: NSView, in bar: AddressBarView) -> ClosedRange<CGFloat>? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        var minX: Int?
        var maxX: Int?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX ?? x, x)
                maxX = max(maxX ?? x, x)
            }
        }
        guard let minX, let maxX else { return nil }
        let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        let origin = view.convert(view.bounds.origin, to: bar).x
        return (origin + CGFloat(minX) / scale)...(origin + CGFloat(maxX + 1) / scale)
    }

    @Test(arguments: [
        ("http://127.0.0.1:17320/42212-harness-update-prompt", BrowserSecurityState.insecure, CGFloat(840)),
        ("http://127.0.0.1:17320/42212-harness-update-prompt", BrowserSecurityState.insecure, CGFloat(420)),
        ("http://neverssl.com/online", BrowserSecurityState.insecure, CGFloat(1200)),
        ("https://github.com/manaflow-ai/cmux", BrowserSecurityState.secure, CGFloat(840)),
        ("file:///Users/me/notes/plan.md", BrowserSecurityState.none, CGFloat(840)),
    ])
    func theAddressStartsRightAfterTheChip(_ url: String, _ security: BrowserSecurityState, _ width: CGFloat) throws {
        let (bar, window) = bar(width: width, url: url, security: security)
        defer { window.closeAfterTest() }
        let chip = bar.pageInfoAnchor
        let field = bar.field

        // The chip is as wide as its icon and label, never stretched by the bar's spare room.
        #expect(chip.frame.minX == OmnibarStyle.chipLeading)
        #expect(chip.frame.width == chip.intrinsicContentSize.width,
                "chip \(chip.frame.width) pt wide, its content \(chip.intrinsicContentSize.width) pt")
        // The field starts one gap after the chip and runs to the bar's trailing side.
        #expect(field.frame.minX == chip.frame.maxX + OmnibarStyle.textLeading,
                "field starts at \(field.frame.minX), chip ends at \(chip.frame.maxX)")
        #expect(field.frame.width > bar.bounds.width / 2, "the field holds the bar's spare width (\(field.frame.width) of \(bar.bounds.width) pt)")

        // The URL's glyphs start at the field's left edge (the cell's 2 pt text inset plus
        // the first glyph's side bearing), not centered or pushed right.
        let text = try #require(inkSpan(field, in: bar))
        #expect(text.lowerBound - field.frame.minX < 6,
                "URL ink starts \(text.lowerBound - field.frame.minX) pt into the field")
        // The chip's label (when it has one) ends before the URL begins: nothing overlaps.
        let chipInk = try #require(inkSpan(chip, in: bar))
        #expect(chipInk.upperBound <= text.lowerBound,
                "chip ink ends at \(chipInk.upperBound), URL ink starts at \(text.lowerBound)")
        #expect(chipInk.upperBound <= chip.frame.maxX, "the chip's label stays inside the chip")
    }
}
