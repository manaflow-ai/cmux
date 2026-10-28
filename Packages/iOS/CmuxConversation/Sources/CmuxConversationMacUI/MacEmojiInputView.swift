#if os(macOS)
import AppKit
import CmuxConversationCore

/// An invisible text input that receives the Character Viewer's insertion
/// for a custom emoji tapback. It accepts exactly one emoji; Escape and other
/// commands pass up the responder chain (Escape closes the picker).
///
/// The view is main-actor (NSView) and so is every requirement it implements;
/// AppKit's input context calls them on the main thread. The conformance says
/// so (an isolated conformance, checked by the compiler) rather than turning
/// the isolation check off.
final class MacEmojiInputView: NSView, @MainActor NSTextInputClient {
    var onEmoji: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard ConversationReaction.isSingleEmoji(text) else { return }
        onEmoji?(text)
    }

    override func doCommand(by selector: Selector) {
        _ = nextResponder?.tryToPerform(selector, with: nil)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// The Character Viewer opens beside this rect: the emoji circle.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}
#endif
