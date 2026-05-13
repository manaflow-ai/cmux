import Foundation

struct MarkdownWebTypography: Equatable {
    struct HeadingSizes: Equatable {
        let h1: Double
        let h2: Double
        let h3: Double
        let h4: Double
        let h5: Double
        let h6: Double
    }

    let fontFamily: String
    let fontSize: Double
    let headingSizes: HeadingSizes
    let codeBlockFontFamily: String
    let codeBlockFontSize: Double

    static let `default` = MarkdownWebTypography(
        fontFamily: MarkdownTypographySettings.defaultFontFamily,
        fontSize: MarkdownTypographySettings.defaultFontSize,
        headingSizes: HeadingSizes(
            h1: MarkdownTypographySettings.defaultHeadingSizes.h1,
            h2: MarkdownTypographySettings.defaultHeadingSizes.h2,
            h3: MarkdownTypographySettings.defaultHeadingSizes.h3,
            h4: MarkdownTypographySettings.defaultHeadingSizes.h4,
            h5: MarkdownTypographySettings.defaultHeadingSizes.h5,
            h6: MarkdownTypographySettings.defaultHeadingSizes.h6
        ),
        codeBlockFontFamily: MarkdownTypographySettings.defaultCodeBlockFontFamily,
        codeBlockFontSize: MarkdownTypographySettings.defaultCodeBlockFontSize
    )

    var cssVariables: [String: String] {
        [
            "--cmux-markdown-font-family": fontFamily,
            "--cmux-markdown-font-size": Self.cssPixels(fontSize),
            "--cmux-markdown-h1-font-size": Self.cssPixels(headingSizes.h1),
            "--cmux-markdown-h2-font-size": Self.cssPixels(headingSizes.h2),
            "--cmux-markdown-h3-font-size": Self.cssPixels(headingSizes.h3),
            "--cmux-markdown-h4-font-size": Self.cssPixels(headingSizes.h4),
            "--cmux-markdown-h5-font-size": Self.cssPixels(headingSizes.h5),
            "--cmux-markdown-h6-font-size": Self.cssPixels(headingSizes.h6),
            "--cmux-markdown-code-block-font-family": codeBlockFontFamily,
            "--cmux-markdown-code-block-font-size": Self.cssPixels(codeBlockFontSize),
        ]
    }

    private static func cssPixels(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded.rounded() == rounded {
            return "\(Int(rounded))px"
        }
        return "\(rounded)px"
    }
}

enum MarkdownTypographySettings {
    struct HeadingSizes: Equatable {
        let h1: Double
        let h2: Double
        let h3: Double
        let h4: Double
        let h5: Double
        let h6: Double
    }

    static let fontFamilyKey = "markdown.typography.fontFamily"
    static let fontSizeKey = "markdown.typography.fontSize"
    static let headingH1SizeKey = "markdown.typography.headingSizes.h1"
    static let headingH2SizeKey = "markdown.typography.headingSizes.h2"
    static let headingH3SizeKey = "markdown.typography.headingSizes.h3"
    static let headingH4SizeKey = "markdown.typography.headingSizes.h4"
    static let headingH5SizeKey = "markdown.typography.headingSizes.h5"
    static let headingH6SizeKey = "markdown.typography.headingSizes.h6"
    static let codeBlockFontFamilyKey = "markdown.typography.codeBlockFontFamily"
    static let codeBlockFontSizeKey = "markdown.typography.codeBlockFontSize"

    static let defaultFontFamily = "-apple-system, BlinkMacSystemFont, \"Segoe UI\", \"Noto Sans\", Helvetica, Arial, sans-serif, \"Apple Color Emoji\", \"Segoe UI Emoji\""
    static let defaultFontSize: Double = 15
    static let defaultHeadingSizes = HeadingSizes(
        h1: 30,
        h2: 22.5,
        h3: 18.75,
        h4: 15,
        h5: 13.13,
        h6: 12.75
    )
    static let defaultCodeBlockFontFamily = "ui-monospace, SFMono-Regular, \"SF Mono\", Menlo, Consolas, \"Liberation Mono\", monospace"
    static let defaultCodeBlockFontSize: Double = 13.5

    static let fontSizeRange: ClosedRange<Double> = 8...32
    static let headingSizeRange: ClosedRange<Double> = 8...72
    static let codeBlockFontSizeRange: ClosedRange<Double> = 8...32

    static func resolved(defaults: UserDefaults = .standard) -> MarkdownWebTypography {
        MarkdownWebTypography(
            fontFamily: resolvedFontFamily(
                defaults.string(forKey: fontFamilyKey),
                fallback: defaultFontFamily
            ),
            fontSize: resolvedSize(
                defaults.object(forKey: fontSizeKey),
                fallback: defaultFontSize,
                range: fontSizeRange
            ),
            headingSizes: MarkdownWebTypography.HeadingSizes(
                h1: resolvedSize(defaults.object(forKey: headingH1SizeKey), fallback: defaultHeadingSizes.h1, range: headingSizeRange),
                h2: resolvedSize(defaults.object(forKey: headingH2SizeKey), fallback: defaultHeadingSizes.h2, range: headingSizeRange),
                h3: resolvedSize(defaults.object(forKey: headingH3SizeKey), fallback: defaultHeadingSizes.h3, range: headingSizeRange),
                h4: resolvedSize(defaults.object(forKey: headingH4SizeKey), fallback: defaultHeadingSizes.h4, range: headingSizeRange),
                h5: resolvedSize(defaults.object(forKey: headingH5SizeKey), fallback: defaultHeadingSizes.h5, range: headingSizeRange),
                h6: resolvedSize(defaults.object(forKey: headingH6SizeKey), fallback: defaultHeadingSizes.h6, range: headingSizeRange)
            ),
            codeBlockFontFamily: resolvedFontFamily(
                defaults.string(forKey: codeBlockFontFamilyKey),
                fallback: defaultCodeBlockFontFamily
            ),
            codeBlockFontSize: resolvedSize(
                defaults.object(forKey: codeBlockFontSizeKey),
                fallback: defaultCodeBlockFontSize,
                range: codeBlockFontSizeRange
            )
        )
    }

    static func normalizedFontFamily(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .newlines) == nil,
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "{};")) == nil else {
            return nil
        }
        return trimmed
    }

    static func normalizedSize(_ raw: Double, range: ClosedRange<Double>) -> Double? {
        guard raw.isFinite, range.contains(raw) else { return nil }
        return (raw * 100).rounded() / 100
    }

    private static func resolvedFontFamily(_ raw: String?, fallback: String) -> String {
        guard let raw,
              let normalized = normalizedFontFamily(raw) else {
            return fallback
        }
        return normalized
    }

    private static func resolvedSize(_ raw: Any?, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let normalized = normalizedSize(number.doubleValue, range: range) else {
            return fallback
        }
        return normalized
    }
}
