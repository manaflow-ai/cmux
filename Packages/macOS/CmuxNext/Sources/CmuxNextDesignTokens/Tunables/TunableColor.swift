public import Foundation

/// A chrome color a tunable may pick: a role of the view's Ghostty-derived
/// theme (`ThemeTokens`). Blue and cyan ANSI colors are left out on purpose
/// (no blue accents anywhere, plans/cmux-next/REWRITE.md).
public nonisolated enum TunableColor: String, Sendable, Hashable, CaseIterable {
    case textPrimary
    case textSecondary
    case textTertiary
    case separator
    case focusRing
    case selectionFill
    case glassTint
    case shadow
    case attention
    case danger
    case success
    case ansiMagenta
    case ansiWhite
    case ansiBrightBlack

    /// The color in `tokens`.
    public func resolve(in tokens: ThemeTokens) -> ThemeRGB {
        switch self {
        case .textPrimary: tokens.textPrimary
        case .textSecondary: tokens.textSecondary
        case .textTertiary: tokens.textTertiary
        case .separator: tokens.separator
        case .focusRing: tokens.focusRing
        case .selectionFill: tokens.selectionFill
        case .glassTint: tokens.glassTint
        case .shadow: tokens.shadow
        case .attention: tokens.attention
        case .danger: tokens.danger
        case .success: tokens.success
        case .ansiMagenta: Self.ansi(tokens, 5, fallback: tokens.textPrimary)
        case .ansiWhite: Self.ansi(tokens, 7, fallback: tokens.textPrimary)
        case .ansiBrightBlack: Self.ansi(tokens, 8, fallback: tokens.textTertiary)
        }
    }

    private static func ansi(_ tokens: ThemeTokens, _ index: Int, fallback: ThemeRGB) -> ThemeRGB {
        tokens.ansi.indices.contains(index) ? tokens.ansi[index] : fallback
    }
}

/// One option of a choice tunable.
public nonisolated struct TunableChoiceOption: Sendable, Hashable {
    public let value: String
    public let title: String

    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}
