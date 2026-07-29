public import Foundation

/// Models the editable text suffix that AppKit input methods expect from an
/// `NSTextInputClient`.
///
/// A terminal cannot retract bytes after they reach the PTY. This session
/// therefore keeps replacement-driven edits provisional until AppKit supplies
/// a semantic commit boundary. It classifies callbacks from event-local state,
/// without inspecting language, script, locale, or input-source identity.
public struct TerminalTextInputEditSession: Sendable {
    private enum MarkedTextOrigin: Sendable {
        case explicit
        case replacementEdits
    }

    private struct Insertion: Sendable {
        let text: String
        let replacementRange: NSRange
    }

    private struct Event: Sendable {
        let translatedText: String?
        let rawText: String?
        var pendingInsertions: [Insertion] = []
        var receivedExplicitCompositionCallback = false
    }

    /// The provisional text currently owned by the input system.
    public private(set) var markedText = ""

    /// The UTF-16 selection inside ``markedText``.
    public private(set) var markedSelection = NSRange(
        location: NSNotFound,
        length: 0
    )

    private var markedTextOrigin: MarkedTextOrigin?
    private var event: Event?

    /// Creates an empty text-input session.
    public init() {}

    /// Whether the input system currently owns provisional text.
    public var hasMarkedText: Bool {
        !markedText.isEmpty
    }

    /// Starts collecting the semantic callbacks produced by one native key.
    ///
    /// - Parameters:
    ///   - translatedText: Text produced after terminal modifier translation.
    ///   - rawText: Text attached to the original native event.
    public mutating func beginEvent(
        translatedText: String?,
        rawText: String? = nil
    ) {
        event = Event(
            translatedText: translatedText,
            rawText: rawText
        )
    }

    /// Finishes one native key and resolves otherwise ambiguous `insertText`
    /// callbacks.
    ///
    /// A consumed callback whose text differs from the key's translated text
    /// is an edit supplied by the text system, rather than direct keyboard
    /// layout output. An initial insertion followed by replacement ranges is
    /// retained as an editable suffix until the replacement covers that suffix.
    ///
    /// - Parameter consumedByTextInput: Whether AppKit claimed the native key.
    /// - Returns: Text that is safe to send irreversibly to the terminal.
    public mutating func finishEvent(
        consumedByTextInput: Bool
    ) -> [String] {
        guard let completedEvent = event else { return [] }
        event = nil

        let insertions = completedEvent.pendingInsertions.filter {
            !$0.text.isEmpty
        }
        guard !insertions.isEmpty else { return [] }

        let insertedText = insertions.map(\.text).joined()
        let correspondsToNativeKey =
            completedEvent.translatedText == insertedText ||
            completedEvent.rawText == insertedText
        guard consumedByTextInput,
              !correspondsToNativeKey,
              !TerminalTextInputText.isSingleC0OrDelete(insertedText),
              !completedEvent.receivedExplicitCompositionCallback,
              markedTextOrigin == nil,
              insertions[0].replacementRange.location == NSNotFound else {
            return insertions.map(\.text)
        }

        markedTextOrigin = .replacementEdits
        return insertions.flatMap {
            applyReplacementEdit(
                $0.text,
                replacementRange: $0.replacementRange
            )
        }
    }

    /// Records AppKit's explicit marked-text state.
    public mutating func setMarkedText(
        _ text: String,
        selectedRange: NSRange
    ) {
        event?.receivedExplicitCompositionCallback = true
        markedText = text
        guard !text.isEmpty else {
            clearMarkedText()
            return
        }

        markedTextOrigin = .explicit
        markedSelection = normalizedSelection(
            selectedRange,
            textLength: utf16Length(of: text)
        )
    }

    /// Commits and removes the active marked text.
    ///
    /// `unmarkText` is AppKit's commit boundary for marked document text. A
    /// caller that needs cancellation must use ``discardMarkedText()``.
    public mutating func unmarkText() -> [String] {
        event?.receivedExplicitCompositionCallback = true
        let committedText = markedText.isEmpty ? [] : [markedText]
        clearMarkedText()
        return committedText
    }

    /// Applies one `insertText` callback and returns text that is safe to send
    /// irreversibly to the terminal.
    public mutating func insertText(
        _ text: String,
        replacementRange: NSRange
    ) -> [String] {
        switch markedTextOrigin {
        case .explicit:
            event?.receivedExplicitCompositionCallback = true
            clearMarkedText()
            return text.isEmpty ? [] : [text]

        case .replacementEdits:
            return applyReplacementEdit(
                text,
                replacementRange: replacementRange
            )

        case nil:
            guard event != nil else {
                return text.isEmpty ? [] : [text]
            }
            if !text.isEmpty {
                event?.pendingInsertions.append(
                    Insertion(
                        text: text,
                        replacementRange: replacementRange
                    )
                )
            }
            return []
        }
    }

    /// Discards provisional state when an explicitly external commit or
    /// cancellation replaces the active composition.
    public mutating func discardMarkedText() {
        event?.receivedExplicitCompositionCallback = true
        clearMarkedText()
    }

    private mutating func applyReplacementEdit(
        _ text: String,
        replacementRange: NSRange
    ) -> [String] {
        let currentLength = utf16Length(of: markedText)
        let effectiveRange = effectiveReplacementRange(
            replacementRange,
            textLength: currentLength
        )

        let replacesWholeBuffer =
            currentLength > 0 &&
            replacementRange.location != NSNotFound &&
            effectiveRange.location == 0 &&
            effectiveRange.length == currentLength
        if replacesWholeBuffer {
            clearMarkedText()
            return text.isEmpty ? [] : [text]
        }

        let mutableText = NSMutableString(string: markedText)
        mutableText.replaceCharacters(in: effectiveRange, with: text)
        markedText = mutableText as String

        guard !markedText.isEmpty else {
            clearMarkedText()
            return []
        }

        markedTextOrigin = .replacementEdits
        markedSelection = normalizedSelection(
            NSRange(
                location: effectiveRange.location + utf16Length(of: text),
                length: 0
            ),
            textLength: utf16Length(of: markedText)
        )
        return []
    }

    private func effectiveReplacementRange(
        _ replacementRange: NSRange,
        textLength: Int
    ) -> NSRange {
        if replacementRange.location == NSNotFound {
            guard markedSelection.location != NSNotFound else {
                return NSRange(location: textLength, length: 0)
            }
            return normalizedSelection(
                markedSelection,
                textLength: textLength
            )
        }

        let location = min(max(replacementRange.location, 0), textLength)
        let length = min(
            max(replacementRange.length, 0),
            textLength - location
        )
        return NSRange(location: location, length: length)
    }

    private func normalizedSelection(
        _ selection: NSRange,
        textLength: Int
    ) -> NSRange {
        guard textLength > 0 else {
            return NSRange(location: NSNotFound, length: 0)
        }
        guard selection.location != NSNotFound else {
            return NSRange(location: textLength, length: 0)
        }

        let location = min(max(selection.location, 0), textLength)
        let length = min(max(selection.length, 0), textLength - location)
        return NSRange(location: location, length: length)
    }

    private mutating func clearMarkedText() {
        markedText = ""
        markedSelection = NSRange(location: NSNotFound, length: 0)
        markedTextOrigin = nil
    }

    private func utf16Length(of text: String) -> Int {
        (text as NSString).length
    }
}
