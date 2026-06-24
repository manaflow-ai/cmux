import Foundation

/// Pure string transforms that decide when a terminal's visible text has caught up to
/// submitted text box content, plus the trimming and needle-extraction helpers the
/// submit pipeline uses to shape what it pastes and waits for.
///
/// Every member is a pure `String -> Bool/String/Int` transform with no stored
/// dependencies and no app-target type touch, so the type is a dependency-free,
/// `Sendable` value. The submit orchestration (event dispatch, completion handling)
/// stays app-side and forwards its matching/trimming/needle calls here.
public struct TextBoxVisibleTextMatcher: Sendable {
    /// Maximum number of characters retained when reducing a long paste to a
    /// visible-text wait needle. Beyond this length the needle is taken from the
    /// trailing portion of the last line so the wait stays cheap and stable.
    public static let visibleTextWaitMaxCharacters = 160

    /// Creates a matcher. The type holds no state; callers can construct one freely.
    public init() {}

    /// The text actually pasted on submit, or `nil` when the input is effectively empty.
    ///
    /// Returns `nil` when `text` is empty after trimming surrounding whitespace and
    /// newlines (the submit is disabled). Otherwise returns `text` with only its
    /// leading/trailing newlines trimmed, preserving surrounding spaces.
    public func submittedPasteText(for text: String) -> String? {
        let trimmedForEnabledState = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedForEnabledState.isEmpty else { return nil }
        return text.trimmingCharacters(in: .newlines)
    }

    /// The substring to wait for in the terminal's visible text after pasting `text`.
    ///
    /// Returns `nil` when `text` has no visible (non-whitespace) content. For short
    /// text the full newline-trimmed text is the needle; for long text the needle is
    /// the trailing `visibleTextWaitMaxCharacters` of the last non-empty line, which is
    /// what remains on screen once the paste settles.
    public func visibleTextWaitNeedle(for text: String) -> String? {
        let nonNewlineTrimmed = text.trimmingCharacters(in: .newlines)
        guard !nonNewlineTrimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard nonNewlineTrimmed.count > Self.visibleTextWaitMaxCharacters else {
            return text
        }

        let lastLine = nonNewlineTrimmed
            .split(omittingEmptySubsequences: false) { character in
                character == "\n" || character == "\r"
            }
            .last
            .map(String.init) ?? nonNewlineTrimmed
        let visibleLine = lastLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nonNewlineTrimmed
            : lastLine
        return String(visibleLine.suffix(Self.visibleTextWaitMaxCharacters))
    }

    /// `text` with its leading newline characters (`\n` and `\r`) removed.
    public func trimmingLeadingNewlines(_ text: String) -> String {
        String(text.drop { character in
            character == "\n" || character == "\r"
        })
    }

    /// `text` with its trailing newline characters (`\n` and `\r`) removed.
    public func trimmingTrailingNewlines(_ text: String) -> String {
        var result = text
        while let last = result.last,
              last == "\n" || last == "\r" {
            result.removeLast()
        }
        return result
    }

    /// Whether the terminal's `visibleText` now reflects the submitted `expectedText`,
    /// relative to the `baseline` captured before the paste.
    ///
    /// When `expectedText` is blank, any change from `baseline` counts as ready. Otherwise
    /// readiness means a fresh occurrence of `expectedText` appeared since `baseline`, or
    /// (when whitespace normalization changes the text) a fresh occurrence of the
    /// whitespace-normalized expected text appeared in the normalized visible text.
    public func visibleTextReady(
        expectedText: String,
        visibleText: String,
        baseline: String
    ) -> Bool {
        let trimmedExpectedText = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExpectedText.isEmpty else {
            return visibleText != baseline
        }
        if occurrenceCount(of: expectedText, in: visibleText) >
            occurrenceCount(of: expectedText, in: baseline) {
            return true
        }

        let normalizedExpected = normalizedVisibleText(trimmedExpectedText)
        guard !normalizedExpected.isEmpty,
              normalizedExpected != expectedText else {
            return false
        }
        return occurrenceCount(of: normalizedExpected, in: normalizedVisibleText(visibleText)) >
            occurrenceCount(of: normalizedExpected, in: normalizedVisibleText(baseline))
    }

    /// The number of non-overlapping occurrences of `needle` in `haystack`.
    public func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    /// `text` with every run of whitespace collapsed to a single space.
    public func normalizedVisibleText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
