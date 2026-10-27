#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// An invisible field that raises the emoji keyboard for a custom emoji
/// tapback and reports the first emoji typed. It never holds text.
///
/// UIKit has no public emoji keyboard type; a responder whose
/// `textInputMode` is the emoji input mode gets the emoji keyboard, as
/// Messages' "Add custom emoji reaction" shows. Without an emoji input mode
/// enabled it falls back to the user's current keyboard, which can still
/// switch to emoji.
final class EmojiInputField: UITextField, UITextFieldDelegate {
    var onEmoji: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        alpha = 0
        autocorrectionType = .no
        spellCheckingType = .no
        accessibilityElementsHidden = true
        // No predictive bar: Messages' picker shows only the emoji keyboard.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }

    /// A context of its own, so the system does not restore the composer's
    /// keyboard over the emoji one.
    override var textInputContextIdentifier: String? { "conversation.tapback.emoji" }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if ConversationReaction.isSingleEmoji(string) { onEmoji?(string) }
        return false
    }
}
#endif
