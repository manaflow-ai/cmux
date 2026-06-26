public import Foundation

extension OmnibarInlineCompletion {
    /// The inline completion to render after the typed query, or `nil` when no
    /// suggestion can extend the typed text in place. Picks the first suggestion
    /// whose completion (or title) prefixes the typed query, normalizes its
    /// display form to scheme/`www.` parity with what the user typed, and only
    /// commits when the resulting selection sits at a state the field editor can
    /// keep alive (caret at the typed boundary, the inline suffix, a select-all,
    /// or the transient typed-prefix selection during Command+A).
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
            guard let completion = suggestion.autocompletionCompletion else { return false }
            return OmnibarSuggestion.matchesTypedPrefix(
                typedText: query,
                suggestionCompletion: completion,
                suggestionTitle: suggestion.autocompletionTitle
            )
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
                displayText = acceptedText.strippingHTTPSchemePrefix
            } else {
                displayText = acceptedText.strippingHTTPSchemeAndWWWPrefix
            }
        } else if let hostOnlyDisplay = Self.hostDisplayText(
            for: acceptedText,
            typedIncludesScheme: typedIncludesScheme,
            typedIncludesWWWPrefix: typedIncludesWWWPrefix
        ) {
            displayText = hostOnlyDisplay
        } else {
            if typedIncludesScheme {
                displayText = acceptedText
            } else if typedIncludesWWWPrefix {
                displayText = acceptedText.strippingHTTPSchemePrefix
            } else {
                displayText = acceptedText.strippingHTTPSchemeAndWWWPrefix
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

    /// The selection range the field editor should adopt for this completion given
    /// the editor's current selection: a select-all, an exact inline-suffix, or the
    /// typed-prefix selection is preserved as-is; anything else collapses to the
    /// inline suffix so the suggestion stays highlighted.
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

    /// The text the SwiftUI buffer should publish when the field reports a change:
    /// when the field still shows the full inline display text and the selection is
    /// at an inline-completion state, publish only the typed text (so the buffer
    /// tracks what the user typed); otherwise publish the field value verbatim.
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

    /// `inlineCompletion` when `bufferText` still equals its typed prefix (the
    /// completion is still live for the current buffer), otherwise `nil`.
    public static func ifBufferMatchesTypedPrefix(
        bufferText: String,
        inlineCompletion: OmnibarInlineCompletion?
    ) -> OmnibarInlineCompletion? {
        guard let inlineCompletion else { return nil }
        guard bufferText == inlineCompletion.typedText else { return nil }
        return inlineCompletion
    }

    /// Whether the typed query carries an explicit path, query, or fragment (after
    /// stripping any scheme), meaning the inline completion should preserve the full
    /// accepted text rather than collapse to a host-only display.
    private static func typedQueryHasExplicitPathOrQuery(_ typedQuery: String) -> Bool {
        var normalized = typedQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("https://") {
            normalized.removeFirst("https://".count)
        } else if normalized.hasPrefix("http://") {
            normalized.removeFirst("http://".count)
        }
        return normalized.contains("/") || normalized.contains("?") || normalized.contains("#")
    }

    /// The host-only inline display form of `acceptedText` (scheme and `www.`
    /// normalized to match what the user typed, default ports dropped), or `nil`
    /// when the accepted text has no parseable host.
    private static func hostDisplayText(
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
