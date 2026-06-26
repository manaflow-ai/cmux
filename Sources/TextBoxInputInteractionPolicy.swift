import AppKit
import Carbon.HIToolbox

/// Pure UI-input policy decisions for the prompt/command text box: when a plain
/// arrow key is handled locally instead of forwarded to the terminal, when
/// external text should overwrite the field, when the placeholder shows, when
/// submit is enabled/allowed, and which lowercased shortcut character a key
/// event maps to. Holds the keyboard-translation seams as constructor-injected
/// dependencies so tests can substitute deterministic translators.
struct TextBoxInputInteractionPolicy {
    typealias KeyTranslator = (UInt16, NSEvent.ModifierFlags) -> String?
    typealias CharacterNormalizer = (NSEvent) -> String

    /// Maps a key code + modifier flags to its layout character (defaults to the
    /// current keyboard layout via `KeyboardLayout`).
    let translateKey: KeyTranslator
    /// Resolves the normalized characters for an event (defaults to
    /// `KeyboardLayout.normalizedCharacters(for:)`).
    let normalizedCharacters: CharacterNormalizer

    init(
        translateKey: @escaping KeyTranslator = KeyboardLayout.character(forKeyCode:modifierFlags:),
        normalizedCharacters: @escaping CharacterNormalizer = KeyboardLayout.normalizedCharacters(for:)
    ) {
        self.translateKey = translateKey
        self.normalizedCharacters = normalizedCharacters
    }

    /// Whether a plain (unmodified) arrow key should be handled by the text box
    /// itself rather than forwarded, never while IME marked text is active.
    func shouldHandlePlainArrowLocally(
        keyCode: UInt16,
        firstResponderHasMarkedText: Bool,
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard !firstResponderHasMarkedText else { return false }
        let normalizedFlags = flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard normalizedFlags.isEmpty else { return false }

        switch Int(keyCode) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            return true
        default:
            return false
        }
    }

    /// Whether externally-provided text should be synchronized into the field,
    /// only when there are no inline attachments, no marked text, and the value
    /// actually differs.
    func shouldSynchronizeExternalText(
        inlineAttachmentCount: Int,
        plainText: String,
        externalText: String,
        hasMarkedText: Bool
    ) -> Bool {
        inlineAttachmentCount == 0 && !hasMarkedText && plainText != externalText
    }

    /// Whether the placeholder should be shown (empty field, no attachments, no
    /// active IME marked text).
    func shouldShowPlaceholder(
        text: String,
        attachmentCount: Int,
        hasMarkedText: Bool
    ) -> Bool {
        text.isEmpty && attachmentCount == 0 && !hasMarkedText
    }

    /// Whether the submit affordance should be enabled.
    func shouldEnableSubmit(
        text: String,
        attachmentCount: Int,
        hasPendingAttachmentUpload: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        !hasPendingAttachmentUpload
            && !hasMarkedText
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentCount > 0)
    }

    /// Whether a submit attempt should proceed (no pending upload, no marked text).
    func shouldSubmit(
        hasPendingAttachmentUpload: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        !hasPendingAttachmentUpload && !hasMarkedText
    }

    /// The lowercased single-character shortcut key for an event, preferring the
    /// layout-translated Command character when it is a single ASCII character,
    /// otherwise the normalized characters.
    func commandShortcutKey(for event: NSEvent) -> String {
        if let translated = translateKey(event.keyCode, event.modifierFlags)?.lowercased(),
           translated.count == 1,
           translated.allSatisfy(\.isASCII) {
            return translated
        }
        return normalizedCharacters(event).lowercased()
    }
}
