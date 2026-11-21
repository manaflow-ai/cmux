import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// An address longer than the bar (Lawrence 2026-11-20, a claude.ai sign-in URL: "very buggy, there is layout shift
/// and the text overflows too much"). At rest the address ran past the field, under the star and the extension
/// buttons, to the window's edge; focusing it moved the text 5 pt left, and blurring moved it back. The resting
/// address ends inside the field, and focus moves none of its pixels.
@MainActor
@Suite(.closesItsWindows)
struct OmnibarLongAddressTests {
    nonisolated static let longAddress = "https://claude.ai/login?selectAccount=true&from=logout&returnTo=%2Foauth%2Fauthorize%3Fcode%3Dtrue%26client_id%3D9d1c250a-e61b-44d9-88ed-5944d1962f5e%26response_type%3Dcode%26redirect_uri%3Dhttps%253A%252F%252Fconsole.anthropic.com%252Foauth%252Fcode%252Fcallback%26scope%3Dorg%253Acreate_api_key%2Buser%253Aprofile"
    nonisolated static let shortAddress = "https://claude.ai/login"

    /// A 520 pt bar in a 900 pt window, with the bookmark star shown as in a browser tab: the window runs 370 pt past
    /// the bar, room for any overflow to show.
    private func bar(_ address: String) throws -> (AddressBarView, NSWindow) {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.widthAnchor.constraint(equalToConstant: 520),
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
        bar.update(url: try #require(URL(string: address)), security: .secure)
        bar.setBookmarkStar(.off)
        content.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    /// `view` drawn as AppKit draws it into a window, subviews included.
    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The pixels of `a` and `b` that differ inside `rect` (view points, `view` flipped or not), counted.
    private func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: NSRect, of view: NSView) -> Int {
        let scale = CGFloat(a.pixelsWide) / view.bounds.width
        let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
        let xs = max(0, Int((rect.minX * scale).rounded(.up)))..<min(a.pixelsWide, Int((rect.maxX * scale).rounded(.down)))
        let ys = max(0, Int((top * scale).rounded(.up)))..<min(a.pixelsHigh, Int(((top + rect.height) * scale).rounded(.down)))
        var count = 0
        for y in ys {
            for x in xs {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let delta = max(abs(p.redComponent - q.redComponent), abs(p.greenComponent - q.greenComponent),
                                abs(p.blueComponent - q.blueComponent), abs(p.alphaComponent - q.alphaComponent))
                if delta > 0.04 { count += 1 }
            }
        }
        return count
    }

    /// The window past the field's end (the star, the bar's end and the window beyond) looks the same with the long
    /// address as with a short one: nothing of the long one draws there.
    @Test func aLongAddressAtRestDrawsNothingPastTheField() throws {
        let (long, longWindow) = try bar(Self.longAddress)
        defer { longWindow.closeAfterTest() }
        let (short, shortWindow) = try bar(Self.shortAddress)
        defer { shortWindow.closeAfterTest() }
        let content = try #require(longWindow.contentView)
        #expect(long.field.frame == short.field.frame, "the field's frame does not depend on the address")
        let fieldEnd = long.convert(long.field.frame, to: content)
        let past = NSRect(x: fieldEnd.maxX, y: fieldEnd.minY, width: content.bounds.maxX - fieldEnd.maxX, height: fieldEnd.height)
        let changed = differing(try render(content), try render(try #require(shortWindow.contentView)), in: past, of: content)
        #expect(changed == 0, "\(changed) pixels past the field's end (x \(fieldEnd.maxX) pt) differ: the address draws there")
    }

    /// How `field` draws into a canvas 400 pt wider than it, nothing clipping it (macOS 14 lets a view draw past its
    /// bounds): the ink pixels inside the field's width and past its end.
    private func inkInAndPast(_ field: NSTextField, draw: (NSRect) -> Void) throws -> (inside: Int, past: Int) {
        let scale: CGFloat = 2
        let size = NSSize(width: field.bounds.width + 400, height: field.bounds.height)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: size.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let end = Int((field.bounds.maxX * scale).rounded(.up))
        var inside = 0, past = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                if x >= end { past += 1 } else { inside += 1 }
            }
        }
        return (inside, past)
    }

    /// The resting line stays inside the field whatever frame AppKit hands its cell: a scrollable single-line cell is
    /// given a frame as wide as its text, and since macOS 14 no view clips the drawing, so the address ran past the
    /// star and the toolbar buttons to the window's edge.
    @Test func theRestingLineEndsInsideTheFieldWhateverFrameItIsGiven() throws {
        let (bar, window) = try bar(Self.longAddress)
        defer { window.closeAfterTest() }
        let field = bar.field
        let cell = try #require(field.cell)
        let ink = try inkInAndPast(field) { wide in cell.draw(withFrame: wide, in: field) }
        #expect(ink.inside > 0, "the cell drew the address")
        #expect(ink.past == 0, "\(ink.past) ink pixels past the field's end (\(field.bounds.width) pt wide)")
    }

    /// The field, asked to draw a dirty rect wider than itself (macOS 14 views draw past their bounds), puts no ink
    /// past its end either.
    @Test func theFieldDrawsNothingPastItsEnd() throws {
        let (bar, window) = try bar(Self.longAddress)
        defer { window.closeAfterTest() }
        let field = bar.field
        let ink = try inkInAndPast(field) { wide in field.draw(wide) }
        #expect(ink.inside > 0, "the field drew the address")
        #expect(ink.past == 0, "\(ink.past) ink pixels past the field's end (\(field.bounds.width) pt wide)")
    }

    /// No expansion tool tip: AppKit's hover window that redraws a truncated field's whole text over it. Over the
    /// omnibar it drew the long address on top of the star, the extension buttons and the More button to the window's
    /// edge while the pointer rested on the bar, 1.5 to 5 pt off the field's own line, and a click took it away: the
    /// overflow and the shift in Lawrence's video (2026-11-20).
    @Test func aLongAddressShowsNoExpansionToolTip() throws {
        let (bar, window) = try bar(Self.longAddress)
        defer { window.closeAfterTest() }
        let field = bar.field
        let cell = try #require(field.cell)
        let expansion = cell.expansionFrame(withFrame: field.bounds, in: field)
        #expect(!field.allowsExpansionToolTips, "the field allows expansion tool tips (its cell's expansion frame: \(expansion))")
        #expect(expansion.isEmpty, "the cell asks for an expansion tool tip \(expansion) over a \(field.bounds.width) pt field")
    }

    /// The opaque glyph pixel box of the field, in backing pixels from its top left.
    private func inkBox(_ field: NSView) throws -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let rep = try render(field)
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                box = (min(box?.minX ?? x, x), min(box?.minY ?? y, y), max(box?.maxX ?? x, x), max(box?.maxY ?? y, y))
            }
        }
        return try #require(box)
    }

    /// Focus (Cmd-L: the whole address selected, as the video's click) keeps the long address's first glyph on the same
    /// pixels. At rest the bar shows the address without its scheme and focus shows it whole, as Chrome does; the resting
    /// field is written the whole address too here, so only where each draws it differs.
    @Test func focusingALongAddressMovesNoPixel() throws {
        let (bar, window) = try bar(Self.longAddress)
        defer { window.closeAfterTest() }
        let field = bar.field
        field.write(Self.longAddress, style: .plain)
        let restText = field.stringValue
        let rest = try inkBox(field)
        let restFrame = field.frame

        bar.focus()
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(bar.isEditing)
        // The selection's fill and the caret off: only the glyphs count. The selection itself stays as focus left it.
        editor.selectedTextAttributes = [:]
        editor.insertionPointColor = .clear
        let editing = try inkBox(field)
        let clip = editor.enclosingScrollView?.contentView.bounds ?? editor.superview?.bounds ?? .zero
        let facts = "rest \"\(restText.prefix(24))…\" editing \"\(editor.string.prefix(24))…\"; field \(field.frame), editor \(editor.frame), "
            + "clip \(clip), container origin \(editor.textContainerOrigin), padding \(editor.textContainer?.lineFragmentPadding ?? -1), "
            + "selection \(editor.selectedRange()), title rect \(field.cell?.titleRect(forBounds: field.bounds) ?? .zero)"
        #expect(field.frame == restFrame, "the field keeps its frame")
        #expect(editing.minX == rest.minX, "first glyph: rest x \(rest.minX) px, editing x \(editing.minX) px (\(facts))")
        #expect(editor.string == restText, "focus shows the text written at rest")
        #expect(editing.minY == rest.minY, "text top: rest \(rest.minY) px, editing \(editing.minY) px")
    }
}
