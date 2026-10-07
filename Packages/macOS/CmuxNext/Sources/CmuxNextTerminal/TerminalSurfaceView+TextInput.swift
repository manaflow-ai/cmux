public import AppKit
import GhosttyNextKit

// IME and marked text. Preedit goes to `ghostty_surface_preedit`, the
// candidate window is placed from `ghostty_surface_ime_point`, and text
// committed outside a key event goes to `ghostty_surface_text_input`
// (ghostty.h:1585-1586, :1656).
extension TerminalSurfaceView: NSTextInputClient {
    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    public func selectedRange() -> NSRange {
        guard let surface else { return NSRange(location: NSNotFound, length: 0) }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange(location: NSNotFound, length: 0) }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String:
            markedText = NSMutableAttributedString(string: plain)
        default:
            return
        }
        // Outside keyDown (for example switching layouts mid-composition)
        // the preedit must update now; inside keyDown it syncs afterwards.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    public func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let fontPointer = ghostty_surface_quicklook_font(surface) {
            // Ghostty returns a +1 CTFont.
            let font = Unmanaged<CTFont>.fromOpaque(fontPointer).takeRetainedValue()
            attributes[.font] = font
        }
        let string = String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
        return NSAttributedString(string: string, attributes: attributes)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        let cell = cellPointSize
        var x: Double = 0
        var y: Double = 0
        var width = Double(cell.width)
        var height = Double(cell.height)
        // Quick Look asks for the selection, not the cursor.
        var usedSelection = false
        if range.length > 0, range != selectedRange() {
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                x = text.tl_px_x - 2
                y = text.tl_px_y + 2
                ghostty_surface_free_text(surface, &text)
                usedSelection = true
            }
        }
        if !usedSelection {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        }
        if range.length == 0, width > 0 {
            // A zero-width rect places the dictation indicator at the caret.
            width = 0
            x += Double(cell.width) * Double(range.location)
        }
        // Ghostty reports a top-left origin in points.
        let viewRect = NSRect(x: x, y: bounds.height - y, width: width, height: max(height, Double(cell.height)))
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard let surface else { return }
        let text: String
        switch string {
        case let attributed as NSAttributedString: text = attributed.string
        case let plain as String: text = plain
        default: return
        }
        let hadMarkedText = hasMarkedText()
        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }
        guard !text.isEmpty else { return }
        if hadMarkedText {
            sendCommittedText(text, action: GHOSTTY_ACTION_PRESS)
            return
        }
        // Outside a key event: emoji picker, dictation, services. Typed text,
        // not a paste (ghostty.h:1585).
        text.withCString { pointer in
            ghostty_surface_text_input(surface, pointer, UInt(text.utf8.count))
        }
    }
}
