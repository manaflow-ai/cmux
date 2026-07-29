public import Foundation

/// Models the marked text that AppKit owns for an `NSTextInputClient`.
///
/// AppKit exposes two different semantic operations:
///
/// - `setMarkedText` replaces reversible composition state.
/// - `insertText` supplies committed text.
///
/// A terminal cannot retract bytes after they reach the PTY, so this session
/// retains only text supplied through the marked-text lifecycle. Committed text
/// remains opaque and is delivered immediately, independent of language,
/// script, locale, keyboard layout, or replacement range.
public struct TerminalTextInputEditSession: Sendable {
    private struct Event: Sendable {
        var committedText: [String] = []
    }

    /// The provisional text currently owned by AppKit.
    public private(set) var markedText = ""

    /// The UTF-16 selection inside ``markedText``.
    public private(set) var markedSelection = NSRange(
        location: NSNotFound,
        length: 0
    )

    private var event: Event?

    /// Creates an empty text-input session.
    public init() {}

    /// Whether AppKit currently owns provisional text.
    public var hasMarkedText: Bool {
        !markedText.isEmpty
    }

    /// Starts collecting committed callbacks produced by one native key.
    public mutating func beginEvent() {
        event = Event()
    }

    /// Finishes one native key.
    ///
    /// Every `insertText` callback is already a semantic commit boundary. The
    /// event scope only preserves callback ordering until the caller has the
    /// complete AppKit transition needed by terminal key planning.
    ///
    /// - Returns: Text committed while AppKit interpreted the native key.
    public mutating func finishEvent() -> [String] {
        guard let completedEvent = event else { return [] }
        event = nil
        return completedEvent.committedText
    }

    /// Replaces AppKit's explicit marked-text state.
    public mutating func setMarkedText(
        _ text: String,
        selectedRange: NSRange
    ) {
        markedText = text
        guard !text.isEmpty else {
            clearMarkedText()
            return
        }

        markedSelection = normalizedSelection(
            selectedRange,
            textLength: utf16Length(of: text)
        )
    }

    /// Commits and removes the active marked text.
    ///
    /// `unmarkText` leaves marked document text in place. Because terminal
    /// preedit is only an overlay, the text must be delivered to the PTY when
    /// AppKit ends that marked lifetime without a separate `insertText`.
    public mutating func unmarkText() -> [String] {
        let committedText = markedText.isEmpty ? [] : [markedText]
        clearMarkedText()
        return committedText
    }

    /// Records committed text from AppKit.
    ///
    /// `replacementRange` belongs to AppKit's editable-document contract.
    /// Callers deliberately omit it here because a terminal has no document
    /// range it can safely rewrite after bytes reach the PTY.
    public mutating func insertText(_ text: String) -> [String] {
        if hasMarkedText {
            clearMarkedText()
        }
        guard !text.isEmpty else { return [] }

        if event != nil {
            event?.committedText.append(text)
            return []
        }
        return [text]
    }

    /// Discards marked state when an explicitly external commit or
    /// cancellation replaces the active composition.
    public mutating func discardMarkedText() {
        clearMarkedText()
    }

    /// Commits marked text at an external semantic boundary such as focus loss.
    public mutating func commitPendingText() -> [String] {
        unmarkText()
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
    }

    private func utf16Length(of text: String) -> Int {
        (text as NSString).length
    }
}
