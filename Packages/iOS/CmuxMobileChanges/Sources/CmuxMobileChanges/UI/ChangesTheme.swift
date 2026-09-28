public import SwiftUI

/// Central visual tokens for workspace change lists and diff pages.
public struct ChangesTheme {
    /// Background for an added diff line.
    public let additionBackground: Color
    /// Stronger background for an added intra-line span.
    public let additionEmphasis: Color
    /// Background for a removed diff line.
    public let removalBackground: Color
    /// Stronger background for a removed intra-line span.
    public let removalEmphasis: Color
    /// Background for a hunk header.
    public let hunkHeaderBackground: Color
    /// Text color for a hunk header.
    public let hunkHeaderText: Color
    /// Text color for line-number gutters.
    public let gutterText: Color
    /// Separator color between the gutter and code.
    public let gutterSeparator: Color
    /// Status color for added and untracked files.
    public let addedStatus: Color
    /// Status color for deleted files.
    public let deletedStatus: Color
    /// Vertical padding for one diff row.
    public let rowVerticalPadding: CGFloat
    /// Spacing between rendered diff hunks.
    public let hunkSpacing: CGFloat
    /// Corner radius for grouped containers.
    public let groupedCornerRadius: CGFloat

    /// Resolves all adaptive tokens for a SwiftUI color scheme.
    /// - Parameter colorScheme: Current light or dark appearance.
    public init(colorScheme: ColorScheme) {
        let isDark = colorScheme == .dark
        additionBackground = isDark
            ? Color(red: 46 / 255, green: 160 / 255, blue: 67 / 255, opacity: 0.15)
            : Color(red: 230 / 255, green: 1, blue: 236 / 255)
        additionEmphasis = isDark
            ? Color(red: 46 / 255, green: 160 / 255, blue: 67 / 255, opacity: 0.40)
            : Color(red: 171 / 255, green: 242 / 255, blue: 188 / 255)
        removalBackground = isDark
            ? Color(red: 248 / 255, green: 81 / 255, blue: 73 / 255, opacity: 0.15)
            : Color(red: 1, green: 235 / 255, blue: 233 / 255)
        removalEmphasis = isDark
            ? Color(red: 248 / 255, green: 81 / 255, blue: 73 / 255, opacity: 0.40)
            : Color(red: 1, green: 192 / 255, blue: 192 / 255)
        hunkHeaderBackground = isDark
            ? Color(red: 56 / 255, green: 139 / 255, blue: 253 / 255, opacity: 0.15)
            : Color(red: 221 / 255, green: 244 / 255, blue: 1)
        hunkHeaderText = isDark
            ? Color(red: 139 / 255, green: 181 / 255, blue: 246 / 255)
            : Color(red: 75 / 255, green: 110 / 255, blue: 140 / 255)
        gutterText = Color.secondary.opacity(0.72)
        gutterSeparator = Color.secondary.opacity(0.22)
        addedStatus = Color(red: 46 / 255, green: 160 / 255, blue: 67 / 255)
        deletedStatus = Color(red: 248 / 255, green: 81 / 255, blue: 73 / 255)
        rowVerticalPadding = 2
        hunkSpacing = 8
        groupedCornerRadius = 10
    }
}
