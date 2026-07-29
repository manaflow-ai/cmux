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
    /// A transformed callback without an explicit marked-text lifecycle is
    /// ambiguous: it can be a one-shot commit or the first edit in a document
    /// replacement sequence. The session keeps that suffix reversible, then
    /// flushes it at the next direct or unowned native key. Replacement edits
    /// can continue until a full replacement supplies the committed candidate.
    ///
    /// - Parameters:
    ///   - consumedByTextInput: Whether AppKit claimed the native key.
    ///   - commandPerformed: Whether AppKit delegated a command back to the
    ///     terminal client.
    /// - Returns: Text that is safe to send irreversibly to the terminal.
    public mutating func finishEvent(
        consumedByTextInput: Bool,
        commandPerformed: Bool = false
    ) -> [String] {
        guard let completedEvent = event else { return [] }
        event = nil

        let insertions = completedEvent.pendingInsertions
        guard !insertions.isEmpty else {
            guard markedTextOrigin == .replacementEdits,
                  (!consumedByTextInput || commandPerformed) else {
                return []
            }
            return commitPendingText()
        }

        let insertedText = insertions.map(\.text).joined()
        let correspondsToNativeKey =
            completedEvent.translatedText == insertedText ||
            completedEvent.rawText == insertedText
        let isControlCallback =
            TerminalTextInputText.isSingleC0OrDelete(insertedText)
        let committedInsertions = insertions.compactMap {
            $0.text.isEmpty ? nil : $0.text
        }

        guard consumedByTextInput,
              !correspondsToNativeKey,
              !isControlCallback,
              !completedEvent.receivedExplicitCompositionCallback,
              insertions[0].replacementRange.location == NSNotFound else {
            return committedInsertions
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
            if let event,
               event.translatedText == text ||
               event.rawText == text ||
               TerminalTextInputText.isSingleC0OrDelete(text) {
                let pendingText = commitPendingText()
                let directText = directText(for: text, event: event)
                return pendingText + (directText.isEmpty ? [] : [directText])
            }
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

    /// Commits any reversible suffix at an external semantic boundary such as
    /// focus loss.
    public mutating func commitPendingText() -> [String] {
        let committedText = markedText.isEmpty ? [] : [markedText]
        clearMarkedText()
        return committedText
    }

    private func directText(for text: String, event: Event) -> String {
        guard text == event.rawText,
              TerminalTextInputText.isSingleC0OrDelete(text),
              let translatedText = event.translatedText,
              !translatedText.isEmpty,
              !TerminalTextInputText.isSingleC0OrDelete(translatedText) else {
            return text
        }
        return translatedText
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
