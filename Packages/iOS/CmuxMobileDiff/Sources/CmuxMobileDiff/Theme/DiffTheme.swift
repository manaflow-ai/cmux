public import SwiftUI

/// GitHub-inspired adaptive colors and layout metrics for native diffs.
public struct DiffTheme: Sendable, Equatable {
    /// Added code-cell background.
    public var additionBackground: Color
    /// Added gutter background, slightly stronger than its code cell.
    public var additionGutterBackground: Color
    /// Stronger added intraline background.
    public var additionIntralineBackground: Color
    /// Deleted code-cell background.
    public var deletionBackground: Color
    /// Deleted gutter background, slightly stronger than its code cell.
    public var deletionGutterBackground: Color
    /// Stronger deleted intraline background.
    public var deletionIntralineBackground: Color
    /// Blue-tinted hunk header background.
    public var hunkBackground: Color
    /// Hairline between file regions.
    public var border: Color
    /// Dimmed line-number foreground.
    public var gutterForeground: Color
    /// Fixed gutter horizontal padding.
    public var gutterPadding: CGFloat

    /// Creates a diff theme with GitHub-like adaptive defaults.
    /// - Parameters:
    ///   - additionBackground: Added code-cell fill.
    ///   - additionGutterBackground: Stronger added gutter fill.
    ///   - additionIntralineBackground: Stronger added word-level fill.
    ///   - deletionBackground: Deleted code-cell fill.
    ///   - deletionGutterBackground: Stronger deleted gutter fill.
    ///   - deletionIntralineBackground: Stronger deleted word-level fill.
    ///   - hunkBackground: Hunk and expansion-control fill.
    ///   - border: File-region hairline.
    ///   - gutterForeground: Line-number foreground.
    ///   - gutterPadding: Horizontal line-number padding.
    public init(
        additionBackground: Color = .diffAdaptive(
            light: Color(red: 0.18, green: 0.78, blue: 0.35).opacity(0.10),
            dark: Color(red: 0.18, green: 0.78, blue: 0.35).opacity(0.12)
        ),
        additionGutterBackground: Color = .diffAdaptive(
            light: Color(red: 0.18, green: 0.78, blue: 0.35).opacity(0.16),
            dark: Color(red: 0.18, green: 0.78, blue: 0.35).opacity(0.18)
        ),
        additionIntralineBackground: Color = .diffAdaptive(
            light: Color(red: 0.18, green: 0.78, blue: 0.35).opacity(0.32),
            dark: Color(red: 0.18, green: 0.78, blue: 0.35).opacity(0.34)
        ),
        deletionBackground: Color = .diffAdaptive(
            light: Color(red: 0.97, green: 0.25, blue: 0.25).opacity(0.10),
            dark: Color(red: 0.97, green: 0.25, blue: 0.25).opacity(0.12)
        ),
        deletionGutterBackground: Color = .diffAdaptive(
            light: Color(red: 0.97, green: 0.25, blue: 0.25).opacity(0.16),
            dark: Color(red: 0.97, green: 0.25, blue: 0.25).opacity(0.18)
        ),
        deletionIntralineBackground: Color = .diffAdaptive(
            light: Color(red: 0.97, green: 0.25, blue: 0.25).opacity(0.30),
            dark: Color(red: 0.97, green: 0.25, blue: 0.25).opacity(0.34)
        ),
        hunkBackground: Color = .diffAdaptive(
            light: Color(red: 0.22, green: 0.56, blue: 0.94).opacity(0.12),
            dark: Color(red: 0.22, green: 0.56, blue: 0.94).opacity(0.18)
        ),
        border: Color = .diffAdaptive(light: Color.black.opacity(0.14), dark: Color.white.opacity(0.18)),
        gutterForeground: Color = .secondary,
        gutterPadding: CGFloat = 5
    ) {
        self.additionBackground = additionBackground
        self.additionGutterBackground = additionGutterBackground
        self.additionIntralineBackground = additionIntralineBackground
        self.deletionBackground = deletionBackground
        self.deletionGutterBackground = deletionGutterBackground
        self.deletionIntralineBackground = deletionIntralineBackground
        self.hunkBackground = hunkBackground
        self.border = border
        self.gutterForeground = gutterForeground
        self.gutterPadding = gutterPadding
    }
}

extension EnvironmentValues {
    /// The active native-diff theme.
    @Entry public var diffTheme = DiffTheme()
}
