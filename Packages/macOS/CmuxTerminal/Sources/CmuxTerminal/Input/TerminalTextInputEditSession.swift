public import Foundation

/// The platform-level kind of source that produced a text-input event.
public enum TerminalTextInputSourceKind: Sendable, Equatable {
    /// A keyboard layout maps physical keys directly to committed text.
    case keyboardLayout

    /// An input method can maintain and replace provisional document text.
    case inputMethod
}

/// Models the editable text suffix that AppKit input methods expect from an
/// `NSTextInputClient`.
///
/// A terminal cannot retract bytes after they reach the PTY. This session
/// therefore keeps replacement-driven edits provisional until AppKit supplies
/// a semantic commit boundary. The model is independent of language, script,
/// keyboard layout, and input-source identifier.
public struct TerminalTextInputEditSession: Sendable {
    private enum MarkedTextOrigin: Sendable, Equatable {
        case explicit
        case replacementEdits
    }

    private struct Insertion: Sendable {
        let text: String
        let replacementRange: NSRange
    }

    private struct Event: Sendable {
        let sourceKind: TerminalTextInputSourceKind
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
    public mutating func beginEvent(sourceKind: TerminalTextInputSourceKind) {
        event = Event(sourceKind: sourceKind)
    }

    /// Finishes one native key and resolves otherwise ambiguous `insertText`
    /// callbacks.
    ///
    /// Input methods sometimes use `insertText` plus replacement ranges as an
    /// editable-document protocol without first calling `setMarkedText`.
    /// Direct keyboard layouts and unconsumed events remain immediate commits.
    public mutating func finishEvent(consumedByTextInput: Bool) -> [String] {
        guard let completedEvent = event else { return [] }
        event = nil

        let insertions = completedEvent.pendingInsertions.filter {
            !$0.text.isEmpty
        }
        guard !insertions.isEmpty else { return [] }

        guard consumedByTextInput,
              completedEvent.sourceKind == .inputMethod,
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
        if text.isEmpty {
            clearMarkedText()
            return
        }

        markedTextOrigin = .explicit
        markedSelection = normalizedSelection(
            selectedRange,
            textLength: utf16Length(of: text)
        )
    }

    /// Removes marked state. Replacement-driven document edits become
    /// committed text because AppKit has ended their editable lifetime.
    public mutating func unmarkText() -> [String] {
        event?.receivedExplicitCompositionCallback = true
        let committedText =
            markedTextOrigin == .replacementEdits && !markedText.isEmpty
                ? [markedText]
                : []
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

    /// Discards provisional state when an explicitly external commit replaces
    /// the active composition.
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
            replacementRange.location == 0 &&
            replacementRange.length == currentLength
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
