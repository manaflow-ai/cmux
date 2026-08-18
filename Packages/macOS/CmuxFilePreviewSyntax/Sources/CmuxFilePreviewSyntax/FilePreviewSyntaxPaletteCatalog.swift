/// Supplies GitHub-inspired light and dark native syntax palettes.
public struct FilePreviewSyntaxPaletteCatalog: Sendable {
    private let dark: FilePreviewSyntaxPalette
    private let light: FilePreviewSyntaxPalette

    /// Creates the built-in light and dark palette catalog.
    public init() {
        dark = FilePreviewSyntaxPalette(
            keyword: FilePreviewSyntaxColor(red: 0.98, green: 0.47, blue: 0.66),
            type: FilePreviewSyntaxColor(red: 0.40, green: 0.85, blue: 0.94),
            string: FilePreviewSyntaxColor(red: 0.60, green: 0.84, blue: 0.55),
            number: FilePreviewSyntaxColor(red: 0.95, green: 0.71, blue: 0.49),
            comment: FilePreviewSyntaxColor(red: 0.50, green: 0.56, blue: 0.62),
            function: FilePreviewSyntaxColor(red: 0.55, green: 0.76, blue: 0.99),
            attribute: FilePreviewSyntaxColor(red: 0.85, green: 0.69, blue: 0.99)
        )
        light = FilePreviewSyntaxPalette(
            keyword: FilePreviewSyntaxColor(red: 0.66, green: 0.13, blue: 0.44),
            type: FilePreviewSyntaxColor(red: 0.13, green: 0.42, blue: 0.55),
            string: FilePreviewSyntaxColor(red: 0.13, green: 0.50, blue: 0.20),
            number: FilePreviewSyntaxColor(red: 0.62, green: 0.36, blue: 0.05),
            comment: FilePreviewSyntaxColor(red: 0.40, green: 0.46, blue: 0.52),
            function: FilePreviewSyntaxColor(red: 0.15, green: 0.36, blue: 0.78),
            attribute: FilePreviewSyntaxColor(red: 0.45, green: 0.27, blue: 0.66)
        )
    }

    /// Returns the palette for `appearance`.
    ///
    /// - Parameter appearance: The effective editor appearance.
    /// - Returns: A complete foreground palette.
    public func palette(for appearance: FilePreviewSyntaxAppearance) -> FilePreviewSyntaxPalette {
        switch appearance {
        case .light: light
        case .dark: dark
        }
    }
}
