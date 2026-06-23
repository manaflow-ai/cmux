public import Foundation

/// The inline (ghost-text) completion shown after the typed query: the typed
/// text, the full display text the field shows, and the text committed on Tab.
///
/// The display/selection logic was lifted from the legacy top-level
/// `omnibarInlineCompletion*` functions onto this owning value type; all of it
/// is pure (`NSRange` arithmetic and string normalization) so the field view
/// can call it without holding any AppKit state in the engine.
public struct OmnibarInlineCompletion: Equatable, Sendable {
    public let typedText: String
    public let displayText: String
    public let acceptedText: String

    public init(typedText: String, displayText: String, acceptedText: String) {
        self.typedText = typedText
        self.displayText = displayText
        self.acceptedText = acceptedText
    }

    public var suffixRange: NSRange {
        let typedCount = typedText.utf16.count
        let fullCount = displayText.utf16.count
        return NSRange(location: typedCount, length: max(0, fullCount - typedCount))
    }

    /// Computes the inline completion to show for `typedText` given the current
    /// suggestions and field selection, or `nil` when none should appear.
    public static func forDisplay(
        typedText: String,
        suggestions: [OmnibarSuggestion],
        isFocused: Bool,
        selectionRange: NSRange,
        hasMarkedText: Bool
    ) -> OmnibarInlineCompletion? {
        guard isFocused else { return nil }
        guard !hasMarkedText else { return nil }

        let query = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let loweredQuery = query.lowercased()
        let typedIncludesScheme = loweredQuery.hasPrefix("https://") || loweredQuery.hasPrefix("http://")
        let typedIncludesWWWPrefix = loweredQuery.hasPrefix("www.")
        let queryCount = query.utf16.count

        let urlCandidate = suggestions.first { suggestion in
            suggestion.matchesTypedPrefix(typedText: query)
        }
        guard let candidate = urlCandidate else {
            return nil
        }

        let acceptedText = candidate.completion
        let displayText: String
        if Self.typedQueryHasExplicitPathOrQuery(query) {
            if typedIncludesScheme {
                displayText = acceptedText
            } else if typedIncludesWWWPrefix {
                displayText = acceptedText.omnibarSchemeStripped
            } else {
                displayText = acceptedText.omnibarSchemeAndWWWStripped
            }
        } else if let hostOnlyDisplay = Self.inlineCompletionHostDisplayText(
            for: acceptedText,
            typedIncludesScheme: typedIncludesScheme,
            typedIncludesWWWPrefix: typedIncludesWWWPrefix
        ) {
            displayText = hostOnlyDisplay
        } else {
            if typedIncludesScheme {
                displayText = acceptedText
            } else if typedIncludesWWWPrefix {
                displayText = acceptedText.omnibarSchemeStripped
            } else {
                displayText = acceptedText.omnibarSchemeAndWWWStripped
            }
        }

        guard candidate.supportsAutocompletion(query: query) else { return nil }
        // The display text must start with the typed query so the inline completion
        // visually extends what the user typed rather than replacing it (e.g. a
        // history entry matched via title "localhost:3000" whose URL is google.com
        // should not replace a typed "l" with "g").
        guard displayText.lowercased().hasPrefix(loweredQuery) else { return nil }
        guard displayText.utf16.count > queryCount else {
            return nil
        }

        let displayCount = displayText.utf16.count

        let resolvedSelectionRange: NSRange = {
            if selectionRange.location == NSNotFound {
                return NSRange(location: queryCount, length: 0)
            }
            let clampedLocation = min(selectionRange.location, displayCount)
            let remaining = max(0, displayCount - clampedLocation)
            let clampedLength = min(selectionRange.length, remaining)
            return NSRange(location: clampedLocation, length: clampedLength)
        }()

        let suffixRange = NSRange(location: queryCount, length: max(0, displayCount - queryCount))
        let isCaretAtTypedBoundary = (resolvedSelectionRange.length == 0 && resolvedSelectionRange.location == queryCount)
        let isSuffixSelection = NSEqualRanges(resolvedSelectionRange, suffixRange)
        let isSelectAllSelection = (resolvedSelectionRange.location == 0 && resolvedSelectionRange.length == displayCount)
        // Command+A can briefly report just the typed prefix selection before the full
        // select-all range lands. Keep inline completion alive through that transition.
        let typedPrefixSelection = NSRange(location: 0, length: queryCount)
        let isTypedPrefixSelection = NSEqualRanges(resolvedSelectionRange, typedPrefixSelection)
        guard isCaretAtTypedBoundary || isSuffixSelection || isSelectAllSelection || isTypedPrefixSelection else {
            return nil
        }

        return OmnibarInlineCompletion(typedText: query, displayText: displayText, acceptedText: acceptedText)
    }

    /// The selection range the field should adopt for this inline completion
    /// given its `currentSelection`.
    public func desiredSelectionRange(currentSelection: NSRange) -> NSRange {
        let typedCount = typedText.utf16.count
        let typedPrefixSelection = NSRange(location: 0, length: typedCount)
        let displayCount = displayText.utf16.count
        let isSelectAll = currentSelection.location == 0 && currentSelection.length == displayCount
        if isSelectAll ||
            NSEqualRanges(currentSelection, suffixRange) ||
            NSEqualRanges(currentSelection, typedPrefixSelection) {
            return currentSelection
        }
        return suffixRange
    }

    /// The buffer text the omnibar should publish for a field change, stripping
    /// the inline-completion suffix back to the typed text when appropriate.
    public static func publishedBufferText(
        fieldValue: String,
        inlineCompletion: OmnibarInlineCompletion?,
        selectionRange: NSRange?,
        hasMarkedText: Bool
    ) -> String {
        guard !hasMarkedText else { return fieldValue }
        guard let inlineCompletion else { return fieldValue }
        guard fieldValue == inlineCompletion.displayText else { return fieldValue }
        guard let selectionRange else { return inlineCompletion.typedText }

        let typedCount = inlineCompletion.typedText.utf16.count
        let displayCount = inlineCompletion.displayText.utf16.count
        let typedPrefixSelection = NSRange(location: 0, length: typedCount)
        let isCaretAtTypedBoundary = selectionRange.location == typedCount && selectionRange.length == 0
        let isSuffixSelection = NSEqualRanges(selectionRange, inlineCompletion.suffixRange)
        let isSelectAllSelection = selectionRange.location == 0 && selectionRange.length == displayCount
        let isTypedPrefixSelection = NSEqualRanges(selectionRange, typedPrefixSelection)
        if isCaretAtTypedBoundary || isSuffixSelection || isSelectAllSelection || isTypedPrefixSelection {
            return inlineCompletion.typedText
        }

        return fieldValue
    }

    /// Returns this completion when `bufferText` still equals its typed text,
    /// otherwise `nil` (the user changed the buffer out from under it).
    public func ifBufferMatchesTypedPrefix(bufferText: String) -> OmnibarInlineCompletion? {
        guard bufferText == typedText else { return nil }
        return self
    }

    private static func typedQueryHasExplicitPathOrQuery(_ typedQuery: String) -> Bool {
        var normalized = typedQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("https://") {
            normalized.removeFirst("https://".count)
        } else if normalized.hasPrefix("http://") {
            normalized.removeFirst("http://".count)
        }
        return normalized.contains("/") || normalized.contains("?") || normalized.contains("#")
    }

    private static func inlineCompletionHostDisplayText(
        for acceptedText: String,
        typedIncludesScheme: Bool,
        typedIncludesWWWPrefix: Bool
    ) -> String? {
        guard let components = URLComponents(string: acceptedText),
              var host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return nil
        }

        if !typedIncludesWWWPrefix, host.hasPrefix("www.") {
            host.removeFirst("www.".count)
        }

        let portSuffix: String
        if let port = components.port {
            let scheme = components.scheme?.lowercased()
            let isDefaultPort =
                (scheme == "https" && port == 443) ||
                (scheme == "http" && port == 80)
            portSuffix = isDefaultPort ? "" : ":\(port)"
        } else {
            portSuffix = ""
        }

        let hostWithPort = "\(host)\(portSuffix)"
        if typedIncludesScheme {
            let scheme = (components.scheme?.lowercased() == "http") ? "http" : "https"
            return "\(scheme)://\(hostWithPort)"
        }
        return hostWithPort
    }
}
