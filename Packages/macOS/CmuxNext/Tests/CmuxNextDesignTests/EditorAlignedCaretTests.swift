import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// In an empty ``EditorAlignedTextField`` that has the keyboard, the caret sits at the
/// placeholder's left edge, where the first typed letter will go: just left of the placeholder's
/// "S", by its left side bearing (Lawrence 2026-11-02, of the Cmd+Shift+P palette: "blinking
/// cursor is not fully on left of S of Search"). The cell drew the placeholder 3 pt left of the
/// field editor's line, so the caret cut into the "S". The resting text keeps that x too.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct EditorAlignedCaretTests {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// Where the field sits in its host: away from the edge, so no ink is cut off.
    private static let fieldX: CGFloat = 24

    private struct Drawn {
        /// The caret's x in the host, from the field editor's layout (the caret is not in a cached
        /// drawing).
        let caretX: CGFloat?
        /// The leftmost ink, in points from the host's left edge.
        let inkMinX: CGFloat
    }

    private static func inkMinX(_ view: NSView) throws -> CGFloat {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var minX = Int.max
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                minX = min(minX, x)
                break
            }
        }
        try #require(minX < Int.max, "nothing drawn")
        return CGFloat(minX) / scale
    }

    /// Draws "Search for commands" as the placeholder of an empty field or as its text, with the
    /// field editing or at rest.
    private static func draw(size: CGFloat, asPlaceholder: Bool, editing: Bool) throws -> Drawn {
        _ = NSApplication.shared
        let text = "Search for commands"
        let font = Typography.system(.default, size: size)
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 56))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        let field = EditorAlignedTextField(frame: .zero)
        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        other.isBordered = false
        other.drawsBackground = false
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
        field.frame = NSRect(x: fieldX, y: (host.bounds.height - height) / 2, width: host.bounds.width - 2 * fieldX, height: height)
        host.addSubview(field)
        host.addSubview(other)
        window.makeFirstResponder(editing ? field : other)
        var caretX: CGFloat?
        if let editor = field.currentEditor() as? NSTextView, let layout = editor.layoutManager, let container = editor.textContainer {
            editor.selectedRange = NSRange(location: 0, length: 0)
            layout.ensureLayout(for: container)
            let line = editor.string.isEmpty ? layout.extraLineFragmentRect
                : layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let x = line.minX + container.lineFragmentPadding + editor.textContainerOrigin.x
            caretX = editor.convert(NSPoint(x: x, y: 0), to: host).x
        }
        return Drawn(caretX: caretX, inkMinX: try inkMinX(host))
    }

    @Test(arguments: [12, 13, 14, 16, 18, 22] as [CGFloat])
    func theCaretSitsAtThePlaceholdersLeftEdge(size: CGFloat) throws {
        let placeholder = try Self.draw(size: size, asPlaceholder: true, editing: true)
        let typed = try Self.draw(size: size, asPlaceholder: false, editing: true)
        let caret = try #require(placeholder.caretX)
        // The "S" starts where the typed "S" starts: one glyph, one side bearing.
        #expect(abs(placeholder.inkMinX - typed.inkMinX) <= 0.5,
                "\(size) pt: placeholder S at \(placeholder.inkMinX), typed S at \(typed.inkMinX), caret \(caret)")
        // The caret is at or just left of the "S", never inside it.
        let bearing = placeholder.inkMinX - caret
        #expect(bearing >= -0.25 && bearing <= 1.5, "\(size) pt: placeholder S at \(placeholder.inkMinX), caret \(caret)")
    }

    /// Focus moves no pixel: the resting text and the resting placeholder start where the editor's do.
    @Test(arguments: [12, 16, 18, 22] as [CGFloat])
    func restingTextKeepsItsX(size: CGFloat) throws {
        let typed = try Self.draw(size: size, asPlaceholder: false, editing: true)
        let resting = try Self.draw(size: size, asPlaceholder: false, editing: false)
        let restingPlaceholder = try Self.draw(size: size, asPlaceholder: true, editing: false)
        #expect(abs(resting.inkMinX - typed.inkMinX) <= 0.5, "\(size) pt: resting \(resting.inkMinX), typed \(typed.inkMinX)")
        #expect(abs(restingPlaceholder.inkMinX - typed.inkMinX) <= 0.5,
                "\(size) pt: resting placeholder \(restingPlaceholder.inkMinX), typed \(typed.inkMinX)")
    }
}
