public import AppKit
import CmuxNextInput
import GhosttyNextKit

// IME and marked text, exactly as upstream Ghostty's SurfaceView
// (ghostty-next macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift,
// NSTextInputClient extension; cx-dd5b4 DESIGN.md rule T1). Preedit goes to
// `ghostty_surface_preedit`, the candidate window is placed from
// `ghostty_surface_ime_point`, and all committed text is a key event with the
// text and no physical key, never a paste (upstream #13817).
extension TerminalSurfaceView: NSTextInputClient {
    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    // The range answers are upstream's (empty NSRange(), not NSNotFound): input
    // methods are tuned against them, and "better" answers changed what Zhuyin
    // and Kotoeri do in cmux-classic (#3574).
    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    public func selectedRange() -> NSRange {
        TerminalSelection.read(of: self)?.range ?? NSRange()
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

    /// Upstream takes only text that comes with an event (a key, a click on a candidate, the emoji
    /// picker, dictation): a key typed here, or an input method's text once the window's input tap
    /// dispatched input. A window with no tap takes it.
    private var textComesWithInput: Bool {
        guard keyTextAccumulator == nil, let tap = (window as? InputTapHosting)?.inputTap else { return true }
        return tap.lastDispatched != nil
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
        guard let surface, range.length > 0, let selection = TerminalSelection.read(of: self) else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [:]
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        if let font = unsafe GhosttyTextRead.quickLookFont(surface) {
            attributes[.font] = font
        }
        return NSAttributedString(string: selection.text, attributes: attributes)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        0
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
        if range.length > 0, range != selectedRange(), let selection = TerminalSelection.read(of: self) {
            (x, y, usedSelection) = (selection.topLeft.x - 2, selection.topLeft.y + 2, true)
        }
        if !usedSelection {
            // SAFETY: the view's live surface (TerminalSurfaceView.surface); Ghostty writes one
            // double into each of the four locals, alive for the call.
            unsafe ghostty_surface_ime_point(surface, &x, &y, &width, &height)
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
        guard surface != nil, textComesWithInput else { return }
        let text: String
        switch string {
        case let attributed as NSAttributedString:
            text = attributed.string
        case let plain as NSString:
            // NSString, not String: bridging to String would turn a lone
            // surrogate into U+FFFD before it could be joined.
            text = joiningSurrogates(plain)
        default:
            return
        }
        // insertText ends any preedit.
        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }
        // Outside keyDown: an IME commit on a click or focus change, the emoji
        // picker, dictation. Typed input, never a paste (upstream #13817).
        guard !text.isEmpty else { return }
        sendCommittedText(text, action: GHOSTTY_ACTION_PRESS)
    }

    /// UnicodeHexInput inserts a pair as two calls; a lone trail is dropped as
    /// Terminal.app does (upstream #13737).
    private func joiningSurrogates(_ text: NSString) -> String {
        if text.length == 1, UTF16.isLeadSurrogate(text.character(at: 0)) {
            leadSurrogate = text.character(at: 0)
            return ""
        }
        if text.length == 1, UTF16.isTrailSurrogate(text.character(at: 0)) {
            defer { leadSurrogate = nil }
            guard let lead = leadSurrogate else { return "" }
            return String(decoding: [lead, text.character(at: 0)], as: UTF16.self)
        }
        leadSurrogate = nil
        return text as String
    }
}
