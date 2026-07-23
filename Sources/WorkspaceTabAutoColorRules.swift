import CmuxSettings
import Foundation

/// One keyword → color rule for automatic workspace colors.
///
/// `keyword` is kept as written for display; `foldedKeyword` is the
/// case/diacritic/width-folded form actually used for matching so the same
/// rule fires for `Deploy`, `deploy`, and `ｄｅｐｌｏｙ`.
struct WorkspaceTabAutoColorRule: Equatable {
    let keyword: String
    let foldedKeyword: String
    /// The value as written in settings: a palette name or a `#RRGGBB` hex.
    let colorValue: String
    /// `colorValue` resolved against the palette, always `#RRGGBB`.
    let colorHex: String
}

/// The resolved, ordered set of automatic workspace color rules.
///
/// Rules are stored as an unordered `keyword: color` map, so ordering is
/// derived instead of authored: the longest matching keyword wins (the most
/// specific rule), ties broken alphabetically. That keeps resolution
/// deterministic without asking users to reason about rule order.
///
/// `keyword` is unique across `rules` — entries that trim to the same keyword
/// are collapsed or dropped before ordering, see
/// ``WorkspaceTabAutoColorRules/canonicalized(_:)``. The settings card relies
/// on that to key its rows.
struct WorkspaceTabAutoColorRuleSet: Equatable {
    static let empty = WorkspaceTabAutoColorRuleSet(rules: [])

    /// Ordered longest keyword first; first match wins.
    let rules: [WorkspaceTabAutoColorRule]

    var isEmpty: Bool { rules.isEmpty }

    func matchingRule(forTitle title: String) -> WorkspaceTabAutoColorRule? {
        guard !rules.isEmpty else { return nil }
        let foldedTitle = WorkspaceTabAutoColorRules.folded(title)
        guard !foldedTitle.isEmpty else { return nil }
        return rules.first { foldedTitle.contains($0.foldedKeyword) }
    }

    func colorHex(forTitle title: String) -> String? {
        matchingRule(forTitle: title)?.colorHex
    }

    /// The color a workspace row should draw.
    ///
    /// A color set on the workspace itself (context menu, CLI, restored
    /// session) always wins; rules only fill in when there is none.
    func effectiveColorHex(explicit: String?, title: String) -> String? {
        if let explicit, let normalized = WorkspaceTabColorSettings.normalizedHex(explicit) {
            return normalized
        }
        return colorHex(forTitle: title)
    }
}

/// Persistence and normalization for ``WorkspaceTabAutoColorRuleSet``.
///
/// Rules live in the `workspaceColors.autoColorRules` catalog entry, edited
/// from `~/.config/cmux/cmux.json`, and are read once per settings change
/// into the sidebar's value snapshot — never per row render.
enum WorkspaceTabAutoColorRules {
    static let rulesKey = WorkspaceColorsCatalogSection().autoColorRules.userDefaultsKey

    static func ruleSet(defaults: UserDefaults = .standard) -> WorkspaceTabAutoColorRuleSet {
        guard let raw = defaults.dictionary(forKey: rulesKey) as? [String: String] else {
            return .empty
        }
        return ruleSet(raw: raw, defaults: defaults)
    }

    static func ruleSet(
        raw: [String: String],
        defaults: UserDefaults = .standard
    ) -> WorkspaceTabAutoColorRuleSet {
        guard !raw.isEmpty else { return .empty }
        let palette = WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults)
        let candidates = raw
            .compactMap { rawKeyword, rawColor -> WorkspaceTabAutoColorRule? in
                let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
                let foldedKeyword = folded(keyword)
                guard !foldedKeyword.isEmpty else { return nil }
                guard let hex = WorkspaceTabColorSettings.resolvedColorHex(rawColor, palette: palette) else {
                    return nil
                }
                return WorkspaceTabAutoColorRule(
                    keyword: keyword,
                    foldedKeyword: foldedKeyword,
                    colorValue: rawColor,
                    colorHex: hex
                )
            }
        let rules = canonicalized(candidates)
            .sorted { lhs, rhs in
                if lhs.foldedKeyword.count != rhs.foldedKeyword.count {
                    return lhs.foldedKeyword.count > rhs.foldedKeyword.count
                }
                // Locale-independent tie-breaks: the same rules must resolve to
                // the same color whatever the user's locale is. `folded` uses
                // no locale either, and `keyword` is the final tie-break
                // because two keywords can fold to the same string.
                if lhs.foldedKeyword != rhs.foldedKeyword { return lhs.foldedKeyword < rhs.foldedKeyword }
                return lhs.keyword < rhs.keyword
            }
        return WorkspaceTabAutoColorRuleSet(rules: rules)
    }

    /// Reduces entries that trim to the same keyword down to at most one rule.
    ///
    /// The map is keyed by the keyword *as typed*, so `"deploy"` and
    /// `" deploy "` are two entries that mean one keyword. Left alone they
    /// produce two rules with an identical sort key, which ties the comparator
    /// completely and hands the color to dictionary iteration order — and gives
    /// the settings card two rows with the same `ForEach` identity.
    ///
    /// Duplicates that resolve to the same color collapse. Duplicates that
    /// disagree are dropped entirely: there is no non-arbitrary winner, and
    /// leaving a workspace uncolored is better than painting it a color the
    /// user did not unambiguously ask for. A conflict on one keyword never
    /// affects the others.
    private static func canonicalized(
        _ candidates: [WorkspaceTabAutoColorRule]
    ) -> [WorkspaceTabAutoColorRule] {
        Dictionary(grouping: candidates, by: \.keyword)
            .values
            .compactMap { group in
                // `colorValue` picks the winner among agreeing duplicates so
                // the survivor does not depend on iteration order either.
                guard let winner = group.min(by: { $0.colorValue < $1.colorValue }) else { return nil }
                guard group.allSatisfy({ $0.colorHex == winner.colorHex }) else { return nil }
                return winner
            }
    }

    /// Normalizes a raw `keyword: color` map for persistence: trims keywords,
    /// drops empty ones, and keeps the color value as written so palette names
    /// survive a round-trip.
    static func normalizedRuleMap(_ rawRules: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (rawKeyword, rawColor) in rawRules {
            let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            let color = rawColor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty, !color.isEmpty else { continue }
            normalized[keyword] = WorkspaceTabColorSettings.normalizedHex(color) ?? color
        }
        return normalized
    }

    /// Locale-independent folding so matching never depends on the user's
    /// current locale (Turkish dotless-i and friends).
    static func folded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
    }
}
