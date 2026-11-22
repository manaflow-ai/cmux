public import Foundation

/// Text rules of the quick index: how input and rows split into words.
public nonisolated struct OmniboxText {
    public init() {}

    /// Longer input gets only the what-you-typed row: no index lookup and no
    /// remote fetch.
    public static let maxInputLength = 2_048
    /// Tokens past this many are ignored.
    public static let maxTokens = 8

    /// Lowercased, whitespace-separated tokens of typed text.
    public static func queryTokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).prefix(maxTokens).map(String.init)
    }

    /// Lowercased runs of letters and digits ("github.com/manaflow-ai" is
    /// github, com, manaflow, ai).
    public static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Typed text as the start of a URL: lowercased, without a scheme and a
    /// leading `www.`, the way `BrowserURLDisplay` shows hosts.
    public static func urlPrefix(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text
    }
}

/// The quick index score, pure and deterministic
/// (plans/cmux-next/omnibar-suggestions.md, "Quick history index"):
///
///     match + typedBoost + log2(visitCount) * 40 + recency + brevity
///
/// `match` is the mean over input tokens of 600 (host prefix, first token),
/// 450 (URL prefix, first token), 300 (title word start) or 150 (substring);
/// a token that matches nothing drops the row. `typedBoost` is 200 when the
/// URL was typed at least once, `recency` is `120 * exp(-ageDays / 14)` and
/// `brevity` is `max(0, 40 - urlLength / 4)` (the site root beats deep pages).
public nonisolated struct OmniboxQuickScore {
    public init() {}

    public static let hostPrefix: Double = 600
    public static let urlPrefix: Double = 450
    public static let titleWord: Double = 300
    public static let substring: Double = 150
    public static let typedBoost: Double = 200
    /// The most `recency` adds (an upper bound for pruning).
    static let maxRecency: Double = 120

    /// The match term for lowercased `tokens`, or nil when a token matches
    /// neither the URL nor the title. `spaced` is each token with a leading
    /// space; `titleSpaced` is the lowercased title with one.
    public static func match(tokens: [String], spaced: [String], host: String, url: String, titleSpaced: String) -> Double? {
        guard !tokens.isEmpty else { return nil }
        var total: Double = 0
        for (index, token) in tokens.enumerated() {
            if index == 0, host.hasPrefix(token) {
                total += hostPrefix
            } else if index == 0, url.hasPrefix(token) {
                total += urlPrefix
            } else if titleSpaced.contains(spaced[index]) {
                total += titleWord
            } else if url.contains(token) || titleSpaced.contains(token) {
                total += substring
            } else {
                return nil
            }
        }
        return total / Double(tokens.count)
    }

    /// `typedBoost + log2(visitCount) * 40`: the part that does not depend
    /// on the input or the time.
    public static func usage(visitCount: Int, typedCount: Int) -> Double {
        (typedCount > 0 ? typedBoost : 0) + log2(Double(max(visitCount, 1))) * 40
    }

    public static func recency(lastVisit: Date, now: Date) -> Double {
        120 * exp(-max(now.timeIntervalSince(lastVisit), 0) / 86_400 / 14)
    }

    public static func brevity(urlLength: Int) -> Double {
        max(0, 40 - Double(urlLength) / 4)
    }

    /// The whole score of a row whose input matched with `match`.
    public static func score(match: Double, visitCount: Int, typedCount: Int, lastVisit: Date, now: Date, urlLength: Int) -> Double {
        match + usage(visitCount: visitCount, typedCount: typedCount) + recency(lastVisit: lastVisit, now: now) + brevity(urlLength: urlLength)
    }

    /// Inline autocomplete may complete to a row only when the input is the
    /// start of its URL at the host (a label boundary, "git" for
    /// github.com/) and the URL was typed once or visited at least 4 times.
    public static func allowsInlineCompletion(hostPrefix: Bool, visitCount: Int, typedCount: Int) -> Bool {
        hostPrefix && (typedCount > 0 || visitCount >= 4)
    }
}
