import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// An ``EditorAlignedTextField`` in single-line mode draws its placeholder, and its text at rest,
/// on the line the field editor types on, in the bundled UI font at every chrome size: AppKit's
/// string drawing put Inter's placeholder up to 4 pt above typed text (the palette's "Search for
/// commands…", Lawrence 2026-10-29).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct EditorAlignedTextFieldTests {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// The ink box, in points, of what `view` draws.
    private static func ink(_ view: NSView) throws -> NSRect? {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        // Past the caret at the text's start.
        for y in 0..<rep.pixelsHigh {
            for x in Int(8 * scale)..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// Draws `text` (or the same words as the placeholder when `asPlaceholder`) with the field
    /// editing or at rest, and returns its ink box.
    private static func draw(size: CGFloat, text: String, asPlaceholder: Bool, editing: Bool) throws -> NSRect? {
        _ = NSApplication.shared
        let font = Typography.system(.default, size: size)
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 360, height: 48))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        let field = EditorAlignedTextField(frame: .zero)
        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = .black
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        field.stringValue = asPlaceholder ? "" : text
        let height = ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1e6, height: 1e6)).height ?? 20)
        field.frame = NSRect(x: 0, y: (host.bounds.height - height) / 2, width: host.bounds.width, height: height)
        host.addSubview(field)
        host.addSubview(other)
        window.makeFirstResponder(editing ? field : other)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
        return try ink(host)
    }

    @Test(arguments: [12, 14, 16, 18] as [CGFloat])
    func placeholderAndRestingTextSitWhereTypedTextDoes(size: CGFloat) throws {
        let text = "Search for commands"
        let typed = try #require(try Self.draw(size: size, text: text, asPlaceholder: false, editing: true))
        for (asPlaceholder, editing) in [(true, true), (true, false), (false, false)] {
            let drawn = try #require(try Self.draw(size: size, text: text, asPlaceholder: asPlaceholder, editing: editing))
            #expect(abs(drawn.minY - typed.minY) <= 0.5 && abs(drawn.maxY - typed.maxY) <= 0.5,
                    "\(size) pt placeholder=\(asPlaceholder) editing=\(editing): \(drawn) vs typed \(typed)")
            #expect(abs(drawn.minX - typed.minX) <= 0.5, "\(size) pt placeholder=\(asPlaceholder) editing=\(editing): \(drawn) vs typed \(typed)")
        }
    }

    /// The cell keeps the placeholder, so the field editor never draws a copy at its own baseline,
    /// and an AX client still reads it.
    @Test func thePlaceholderStaysOffTheFieldEditor() throws {
        _ = NSApplication.shared
        let field = EditorAlignedTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        field.placeholderString = "Search"
        #expect(field.placeholderString == "Search")
        #expect(field.cell?.accessibilityPlaceholderValue() == "Search")
        #expect((field.cell as? NSTextFieldCell)?.placeholderAttributedString == nil)
        #expect((field.cell as? NSTextFieldCell)?.placeholderString == nil)
    }
}
