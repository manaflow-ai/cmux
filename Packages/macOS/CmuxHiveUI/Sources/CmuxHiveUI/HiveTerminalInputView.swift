public import AppKit
public import CmuxMobileTerminalKit
public import SwiftUI

/// First-responder key capture for the remote terminal: an invisible AppKit
/// view that turns key presses into terminal input actions.
///
/// AppKit is the only complete source of raw key events (SwiftUI's `onKeyPress`
/// drops modifier detail), so this mirrors how the local terminal receives
/// keys — an NSView in the responder chain — while the mapping itself stays in
/// the pure ``HiveTerminalKeyMapping`` table.
public struct HiveTerminalInputView: NSViewRepresentable {
    /// Closure bundle for the capture view's actions (snapshot-boundary rule:
    /// the AppKit view holds closures, never a store).
    public struct Actions {
        var sendText: (String) -> Void
        var sendSpecial: (TerminalSpecialKey, TerminalKeyModifier) -> Void
        var sendControl: (String) -> Void

        public init(
            sendText: @escaping (String) -> Void,
            sendSpecial: @escaping (TerminalSpecialKey, TerminalKeyModifier) -> Void,
            sendControl: @escaping (String) -> Void
        ) {
            self.sendText = sendText
            self.sendSpecial = sendSpecial
            self.sendControl = sendControl
        }
    }

    private let actions: Actions
    private let isFocused: Bool

    /// Creates the input capture layer.
    /// - Parameters:
    ///   - actions: Where key input is routed.
    ///   - isFocused: When `true`, the view claims first responder.
    public init(actions: Actions, isFocused: Bool) {
        self.actions = actions
        self.isFocused = isFocused
    }

    public func makeNSView(context: Context) -> HiveTerminalKeyCaptureNSView {
        let view = HiveTerminalKeyCaptureNSView()
        view.actions = actions
        return view
    }

    public func updateNSView(_ nsView: HiveTerminalKeyCaptureNSView, context: Context) {
        nsView.actions = actions
        nsView.setInputEnabled(isFocused)
    }
}

/// The AppKit key-capture view backing ``HiveTerminalInputView``.
public final class HiveTerminalKeyCaptureNSView: NSView, @preconcurrency NSTextInputClient {
    var actions: HiveTerminalInputView.Actions?
    private var inputEnabled = false
    private var didRequestInitialFocus = false
    private var markedText = NSMutableAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)

    override public var acceptsFirstResponder: Bool { true }

    func setInputEnabled(_ enabled: Bool) {
        inputEnabled = enabled
        if !enabled {
            didRequestInitialFocus = false
            if window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
            unmarkText()
        } else {
            claimInitialFocusIfNeeded()
        }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimInitialFocusIfNeeded()
    }

    private func claimInitialFocusIfNeeded() {
        guard inputEnabled, !didRequestInitialFocus, let window else { return }
        didRequestInitialFocus = true
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }

    override public func mouseDown(with event: NSEvent) {
        guard inputEnabled else { return }
        window?.makeFirstResponder(self)
    }

    override public func keyDown(with event: NSEvent) {
        guard inputEnabled else {
            super.keyDown(with: event)
            return
        }
        // Cmd+V pastes into the remote PTY; every other Command chord stays
        // with the app (the mapping returns nil for Command).
        let deviceIndependentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if deviceIndependentFlags == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            if let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty {
                actions?.sendText(pasted)
            }
            return
        }
        guard let action = HiveTerminalKeyMapping.action(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags
        ) else {
            super.keyDown(with: event)
            return
        }
        switch action {
        case .special(let key, let modifiers):
            actions?.sendSpecial(key, modifiers)
        case .control(let character):
            actions?.sendControl(character)
        case .text(_) where event.keyCode == 36 || event.keyCode == 76:
            actions?.sendText("\u{000D}")
        case .text(_) where event.keyCode == 51:
            actions?.sendText("\u{007F}")
        case .text(_):
            // Let AppKit's text system resolve dead keys and IME composition.
            // Committed text arrives through insertText(_:replacementRange:).
            interpretKeyEvents([event])
        }
    }

    // MARK: NSTextInputClient

    /// Deliver committed text, including text finalized by an input method.
    public func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text: String
        switch insertString {
        case let attributed as NSAttributedString:
            text = attributed.string
        case let string as String:
            text = string
        default:
            return
        }
        unmarkText()
        guard inputEnabled, !text.isEmpty else { return }
        actions?.sendText(text)
    }

    /// Store marked (pre-edit) text until the input method commits it.
    public func setMarkedText(
        _ markedText: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        switch markedText {
        case let attributed as NSAttributedString:
            self.markedText = NSMutableAttributedString(attributedString: attributed)
        case let string as String:
            self.markedText = NSMutableAttributedString(string: string)
        default:
            return
        }
        self.markedSelection = clampedRange(selectedRange, length: self.markedText.length)
    }

    /// Clear the current input-method composition.
    public func unmarkText() {
        markedText.mutableString.setString("")
        markedSelection = NSRange(location: 0, length: 0)
    }

    /// Whether an input method currently owns marked text.
    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    /// Return the range occupied by marked text, if any.
    public func markedRange() -> NSRange {
        hasMarkedText()
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    /// Return the input method's current selection range.
    public func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0)
    }

    /// This capture view does not expose custom marked-text attributes.
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// Return marked text for input-method candidate queries.
    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard hasMarkedText() else { return nil }
        let clamped = clampedRange(range, length: markedText.length)
        actualRange?.pointee = clamped
        return markedText.attributedSubstring(from: clamped)
    }

    /// Return a screen rectangle where the input method can place candidates.
    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        let viewRect = NSRect(
            x: 0,
            y: 0,
            width: max(bounds.width, 1),
            height: max(bounds.height, 1)
        )
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    /// The terminal capture view uses one logical caret position.
    public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    /// Handle text-system commands that arrive instead of a raw key event.
    override public func doCommand(by selector: Selector) {
        guard inputEnabled else { return }
        switch selector {
        case #selector(insertNewline(_:)):
            actions?.sendText("\u{000D}")
        case #selector(insertTab(_:)):
            actions?.sendText("\u{0009}")
        case #selector(deleteBackward(_:)):
            actions?.sendText("\u{007F}")
        default:
            break
        }
    }

    private func clampedRange(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(range.location, 0), length)
        let maxLength = max(0, length - location)
        return NSRange(location: location, length: min(max(range.length, 0), maxLength))
    }
}
