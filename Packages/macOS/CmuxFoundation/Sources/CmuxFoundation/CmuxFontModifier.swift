import AppKit
import SwiftUI

/// The app-wide UI font family: Berkeley Mono everywhere when it's installed
/// (checked once at launch), otherwise Inter. Berkeley Mono is a licensed
/// font, so machines without it get the Inter fallback instead of the system
/// font.
public enum CmuxUIFontFamily {
    public static let preferred: String =
        NSFont(name: "Berkeley Mono", size: 12) != nil ? "Berkeley Mono" : "Inter"
}

struct CmuxFontModifier: ViewModifier {
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var percent
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    var monospacedDigit: Bool = false

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        // One family everywhere (Berkeley Mono when installed): monospaced
        // requests always ask for Berkeley Mono; proportional UI text uses the
        // preferred family. Font.custom falls back to the system font if a
        // family is missing.
        let familyName = (design == .monospaced) ? "Berkeley Mono" : CmuxUIFontFamily.preferred
        var font = Font.custom(familyName, size: scaledSize).weight(weight)
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }

    private var scaledSize: CGFloat {
        GlobalFontMagnification.scaledSize(baseSize, percent: percent)
    }
}
