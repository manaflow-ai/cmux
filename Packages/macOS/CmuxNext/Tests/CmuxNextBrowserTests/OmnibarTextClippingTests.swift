import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// No omnibar text is ever cut off (user, 2026-10-27, "file slightly cut
/// off here": the right edge of the "File" chip's "e" was clipped). The
/// chip's label and the address keep every glyph pixel, focused or not,
/// for http and file pages.
@MainActor
@Suite(.closesItsWindows)
struct OmnibarTextClippingTests {
    /// The opaque glyph pixel box of `view`, in backing pixels from its top left.
    private func inkBox(_ view: NSView) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int)? {
        view.superview?.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                box = (min(box?.minX ?? x, x), min(box?.minY ?? y, y), max(box?.maxX ?? x, x), max(box?.maxY ?? y, y))
            }
        }
        return box.map { ($0.minX, $0.minY, $0.maxX, $0.maxY, rep.pixelsWide, rep.pixelsHigh) }
    }

    private func window(_ size: NSSize) -> NSWindow {
        NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    }

    // MARK: Chip label

    nonisolated static let labels: [PageInfoIndicator] = [
        PageInfoIndicator(symbol: PageInfoIndicator.fileSymbol, label: .file, isTriggerable: true),
        PageInfoIndicator(symbol: PageInfoIndicator.notSecureSymbol, label: .notSecure, isTriggerable: true),
        PageInfoIndicator(symbol: PageInfoIndicator.dangerousSymbol, label: .dangerous, tone: .danger, isTriggerable: true),
        PageInfoIndicator(symbol: PageInfoIndicator.productSymbol, label: .product, isTriggerable: true),
        PageInfoIndicator(symbol: PageInfoIndicator.searchSymbol, label: .keyword("Search Google"), isTriggerable: false),
    ]

    /// The chip's label draws every glyph pixel a free-standing label of the
    /// same text and font draws: its frame holds the text and its padding.
    @Test(arguments: labels)
    func chipLabelIsNeverClipped(_ indicator: PageInfoIndicator) throws {
        let chip = PageInfoChipButton()
        let window = window(NSSize(width: 400, height: 60))
        defer { window.closeAfterTest() }
        window.contentView!.addSubview(chip)
        chip.indicator = indicator
        chip.frame = NSRect(origin: NSPoint(x: 10, y: 10), size: chip.intrinsicContentSize)
        chip.layoutSubtreeIfNeeded()
        let label = try #require(chip.subviews.compactMap { $0 as? ChromeLabel }.first { !$0.isHidden })

        let free = ChromeLabel(labelWithString: label.stringValue)
        free.font = label.font
        free.sizeToFit()
        window.contentView!.addSubview(free)
        let reference = try #require(inkBox(free))
        let shown = try #require(inkBox(label))

        #expect(label.frame.width >= label.naturalSize.width,
                "\"\(label.stringValue)\": frame \(label.frame.width) pt, text with padding \(label.naturalSize.width) pt")
        // Never narrower than the whole text; a pixel wider is subpixel placement, not clipping.
        #expect(shown.maxX - shown.minX >= reference.maxX - reference.minX,
                "\"\(label.stringValue)\" ink width: shown \(shown.maxX - shown.minX + 1) px, whole text \(reference.maxX - reference.minX + 1) px")
        #expect(shown.maxX < shown.width - 1, "\"\(label.stringValue)\" ink reaches the label's right edge")
        #expect(label.frame.maxX <= chip.bounds.maxX, "the label stays inside the chip")
    }

    // MARK: Address text

    private func bar(_ url: URL, security: BrowserSecurityState) -> (AddressBarView, NSWindow) {
        let bar = AddressBarView()
        let window = window(NSSize(width: 900, height: 80))
        window.contentView!.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 10),
            bar.widthAnchor.constraint(equalToConstant: 840),
            bar.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        bar.update(url: url, security: security)
        window.contentView!.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    nonisolated static let addresses: [String] = [
        "https://github.com/manaflow-ai/cmuxterm-hq",
        "file:///var/folders/xy/T/report.html",
    ]

    /// The ink height, in pixels at `scale`, of `text` drawn with no frame to clip it.
    private func freeInkHeight(_ text: NSAttributedString, scale: CGFloat) -> Int? {
        let size = text.size()
        let width = Int(ceil(size.width + 20) * scale), height = Int(ceil(size.height + 20) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        text.draw(at: NSPoint(x: 10, y: 10))
        NSGraphicsContext.restoreGraphicsState()
        var top: Int?, bottom: Int?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                top = min(top ?? y, y)
                bottom = max(bottom ?? y, y)
                break
            }
        }
        guard let top, let bottom else { return nil }
        return bottom - top
    }

    /// The address shows its whole glyphs at rest and while editing: its ink is as tall as the
    /// same text drawn with nothing to clip it, and starts inside the field's left edge.
    @Test(arguments: addresses)
    func addressIsNeverClipped(_ address: String) throws {
        let url = try #require(URL(string: address))
        let (bar, window) = bar(url, security: .secure)
        defer { window.closeAfterTest() }
        let field = bar.field
        let probe = try #require(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        let scale = CGFloat(probe.pixelsHigh) / field.bounds.height
        let rest = try #require(inkBox(field))
        let restFree = try #require(freeInkHeight(field.attributedStringValue, scale: scale))
        #expect(rest.minX > 0, "\(address) at rest: ink starts at x \(rest.minX) px")
        #expect(rest.maxY - rest.minY >= restFree,
                "\(address) at rest: ink \(rest.maxY - rest.minY) px tall in the field, \(restFree) px unclipped")

        bar.focus()
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectedTextAttributes = [:]
        editor.insertionPointColor = .clear
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let editing = try #require(inkBox(field))
        let storage = try #require(editor.textStorage)
        let editingFree = try #require(freeInkHeight(storage, scale: scale))
        #expect(editing.minX > 0, "\(address) editing: ink starts at x \(editing.minX) px")
        #expect(editing.maxY - editing.minY >= editingFree,
                "\(address) editing: ink \(editing.maxY - editing.minY) px tall in the field, \(editingFree) px unclipped")
    }
}
