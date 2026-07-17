public import SwiftUI

/// Adaptive visual tokens for GitHub-style diff rendering.
public struct DiffTheme: Sendable, Equatable {
    /// Subtle green fill for added rows.
    public var additionFill: Color
    /// Stronger green fill for changed spans inside additions.
    public var additionEmphasisFill: Color
    /// Subtle red fill for deleted rows.
    public var deletionFill: Color
    /// Stronger red fill for changed spans inside deletions.
    public var deletionEmphasisFill: Color
    /// Blue fill for hunk headers.
    public var hunkFill: Color
    /// Hairline used between gutters and code.
    public var hairline: Color
    /// Secondary foreground for line-number gutters.
    public var gutterForeground: Color

    /// Creates diff tokens with adaptive GitHub-like defaults.
    /// - Parameters:
    ///   - additionFill: Subtle addition background.
    ///   - additionEmphasisFill: Strong addition-span background.
    ///   - deletionFill: Subtle deletion background.
    ///   - deletionEmphasisFill: Strong deletion-span background.
    ///   - hunkFill: Hunk-header background.
    ///   - hairline: Divider color.
    ///   - gutterForeground: Line-number foreground.
    public init(
        additionFill: Color = .diffAdaptive(
            light: Color(red: 0.91, green: 1.0, blue: 0.93),
            dark: Color(red: 0.05, green: 0.25, blue: 0.12)
        ),
        additionEmphasisFill: Color = .diffAdaptive(
            light: Color(red: 0.67, green: 0.94, blue: 0.72),
            dark: Color(red: 0.10, green: 0.42, blue: 0.20)
        ),
        deletionFill: Color = .diffAdaptive(
            light: Color(red: 1.0, green: 0.92, blue: 0.92),
            dark: Color(red: 0.31, green: 0.08, blue: 0.09)
        ),
        deletionEmphasisFill: Color = .diffAdaptive(
            light: Color(red: 1.0, green: 0.72, blue: 0.72),
            dark: Color(red: 0.52, green: 0.13, blue: 0.14)
        ),
        hunkFill: Color = .diffAdaptive(
            light: Color(red: 0.87, green: 0.94, blue: 1.0),
            dark: Color(red: 0.08, green: 0.20, blue: 0.34)
        ),
        hairline: Color = .diffAdaptive(light: Color(white: 0.82), dark: Color(white: 0.27)),
        gutterForeground: Color = .secondary
    ) {
        self.additionFill = additionFill
        self.additionEmphasisFill = additionEmphasisFill
        self.deletionFill = deletionFill
        self.deletionEmphasisFill = deletionEmphasisFill
        self.hunkFill = hunkFill
        self.hairline = hairline
        self.gutterForeground = gutterForeground
    }
}

extension EnvironmentValues {
    /// The active diff rendering tokens.
    @Entry public var diffTheme = DiffTheme()
}
