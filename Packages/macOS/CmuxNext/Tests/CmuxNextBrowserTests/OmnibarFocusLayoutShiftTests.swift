import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Focusing the omnibar moves nothing (user, 2026-10-27, "after focus on
/// omnibar there is layout shift"): the chip, the field, the badges and the
/// address text keep their frames and pixels; only the fill and ring change.
@MainActor
struct OmnibarFocusLayoutShiftTests {
    private let address = "https://github.com/manaflow-ai/cmuxterm-hq"

    private func bar() -> (AddressBarView, NSWindow) {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView!.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 10),
            bar.widthAnchor.constraint(equalToConstant: 840),
            bar.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        bar.update(url: URL(string: address), security: .secure)
        bar.setBookmarkStar(.off)
        window.contentView!.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    /// The pixel box of the field's text (its opaque glyph pixels), in
    /// backing pixels from the field's top left.
    private func inkBox(_ field: NSView) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        field.superview?.layoutSubtreeIfNeeded()
        guard let rep = field.bitmapImageRepForCachingDisplay(in: field.bounds) else { return nil }
        field.cacheDisplay(in: field.bounds, to: rep)
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                box = (min(box?.minX ?? x, x), min(box?.minY ?? y, y), max(box?.maxX ?? x, x), max(box?.maxY ?? y, y))
            }
        }
        return box
    }

    private struct Frames: Equatable {
        var chip: NSRect
        var field: NSRect
        var star: NSRect
    }

    private func frames(_ bar: AddressBarView) -> Frames {
        bar.layoutSubtreeIfNeeded()
        return Frames(chip: bar.pageInfoAnchor.frame, field: bar.field.frame, star: bar.starButton.frame)
    }

    /// The text at rest and while editing sits on the same pixels: the
    /// resting cell and the field editor lay the line out the same way.
    @Test func focusingKeepsTheAddressOnTheSamePixels() throws {
        let (bar, _) = bar()
        // At rest the compact URL drops the scheme; editing shows the full
        // address. Write the same text both ways so only the drawing differs.
        bar.field.write("github.com/manaflow-ai/cmuxterm-hq", style: .plain)
        let rest = try #require(inkBox(bar.field))
        let restFrames = frames(bar)

        bar.focus()
        let editor = try #require(bar.field.currentEditor() as? NSTextView)
        #expect(bar.isEditing)
        // The same text, no selection highlight and no caret, so only the glyphs count.
        editor.string = "github.com/manaflow-ai/cmuxterm-hq"
        editor.selectedTextAttributes = [:]
        editor.insertionPointColor = .clear
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let editing = try #require(inkBox(bar.field))

        #expect(frames(bar) == restFrames, "chip, field and star keep their frames")
        #expect(editing.minX == rest.minX, "text left edge: rest \(rest.minX) px, editing \(editing.minX) px")
        #expect(editing.minY == rest.minY, "text top: rest \(rest.minY) px, editing \(editing.minY) px")
        #expect(editing.maxY == rest.maxY, "text bottom: rest \(rest.maxY) px, editing \(editing.maxY) px")
    }

    /// The bar's own subviews keep their frames through focus and blur.
    @Test func focusAndBlurKeepEveryFrame() {
        let (bar, window) = bar()
        let rest = frames(bar)
        bar.focus()
        #expect(frames(bar) == rest)
        window.makeFirstResponder(nil)
        #expect(frames(bar) == rest)
    }
}
