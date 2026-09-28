public import SwiftUI

extension ANSIArt {
    /// The art as an attributed string for a SwiftUI `Text`, with one line
    /// per art line.
    ///
    /// Each run carries its resolved foreground (at half opacity when dim) and
    /// any background. Bold runs are marked
    /// `InlinePresentationIntent.stronglyEmphasized`, so they take the bold
    /// weight of whatever font the `Text` uses.
    ///
    /// - Parameter palette: The colors to resolve against.
    /// - Returns: The styled text.
    public func attributedString(palette: ANSIArtPalette) -> AttributedString {
        var result = AttributedString()
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 {
                result.append(AttributedString("\n"))
            }
            for run in line.runs {
                var piece = AttributedString(run.text)
                let colors = palette.resolvedColors(for: run.style)
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] =
                    Self.color(colors.foreground, opacity: run.style.isDim ? 0.5 : 1)
                if let background = colors.background {
                    piece[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] =
                        Self.color(background, opacity: 1)
                }
                if run.style.isBold {
                    piece[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] =
                        .stronglyEmphasized
                }
                result.append(piece)
            }
        }
        return result
    }

    private static func color(_ rgb: ANSIArtRGB, opacity: Double) -> Color {
        Color(
            .sRGB,
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255,
            opacity: opacity
        )
    }
}
