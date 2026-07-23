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
        let rules = raw
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
            .sorted { lhs, rhs in
                if lhs.foldedKeyword.count != rhs.foldedKeyword.count {
                    return lhs.foldedKeyword.count > rhs.foldedKeyword.count
                }
                return lhs.keyword.localizedStandardCompare(rhs.keyword) == .orderedAscending
            }
        return WorkspaceTabAutoColorRuleSet(rules: rules)
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
