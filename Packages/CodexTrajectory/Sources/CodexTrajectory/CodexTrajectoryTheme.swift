import CoreGraphics
import CoreText
import CMUXMarkdown

public struct CodexTrajectoryBlockStyle {
    public var font: CTFont
    public var foregroundColor: CGColor
    public var backgroundColor: CGColor?

    public init(font: CTFont, foregroundColor: CGColor, backgroundColor: CGColor? = nil) {
        self.font = font
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }
}

public struct CodexTrajectoryTheme {
    public var identifier: String
    public var contentInsets: CodexTrajectoryInsets
    public var contentInsetsByKind: [CodexTrajectoryBlockKind: CodexTrajectoryInsets]
    public var stylesByKind: [CodexTrajectoryBlockKind: CodexTrajectoryBlockStyle]
    public var fallbackStyle: CodexTrajectoryBlockStyle
    public var markdownKinds: Set<CodexTrajectoryBlockKind>
    public var markdownTheme: CMUXMarkdownCoreTextTheme?

    public init(
        identifier: String,
        contentInsets: CodexTrajectoryInsets = CodexTrajectoryInsets(top: 6, left: 8, bottom: 6, right: 8),
        contentInsetsByKind: [CodexTrajectoryBlockKind: CodexTrajectoryInsets] = [:],
        stylesByKind: [CodexTrajectoryBlockKind: CodexTrajectoryBlockStyle],
        fallbackStyle: CodexTrajectoryBlockStyle,
        markdownKinds: Set<CodexTrajectoryBlockKind> = [.assistantText],
        markdownTheme: CMUXMarkdownCoreTextTheme? = nil
    ) {
        self.identifier = identifier
        self.contentInsets = contentInsets
        self.contentInsetsByKind = contentInsetsByKind
        self.stylesByKind = stylesByKind
        self.fallbackStyle = fallbackStyle
        self.markdownKinds = markdownKinds
        self.markdownTheme = markdownTheme
    }

    public func style(for kind: CodexTrajectoryBlockKind) -> CodexTrajectoryBlockStyle {
        stylesByKind[kind] ?? fallbackStyle
    }

    public func contentInsets(for kind: CodexTrajectoryBlockKind) -> CodexTrajectoryInsets {
        contentInsetsByKind[kind] ?? contentInsets
    }

    public func markdownTheme(for kind: CodexTrajectoryBlockKind) -> CMUXMarkdownCoreTextTheme? {
        guard markdownKinds.contains(kind) else { return nil }
        if let markdownTheme {
            return markdownTheme
        }
        let style = self.style(for: kind)
        let monoStyle = self.style(for: .toolCall)
        return CMUXMarkdownCoreTextTheme(
            baseFont: style.font,
            monospacedFont: monoStyle.font,
            foregroundColor: style.foregroundColor,
            mutedColor: self.style(for: .status).foregroundColor,
            linkColor: CGColor(red: 0.34, green: 0.55, blue: 0.92, alpha: 1),
            codeColor: monoStyle.foregroundColor,
            paragraphSpacing: 8,
            lineSpacing: 3
        )
    }

    public static func defaultLight(
        textSize: CGFloat = 13,
        monospacedSize: CGFloat = 12
    ) -> CodexTrajectoryTheme {
        let textFont = CTFontCreateUIFontForLanguage(.system, textSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, textSize, nil)
        let monospacedFont = CTFontCreateUIFontForLanguage(.userFixedPitch, monospacedSize, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, monospacedSize, nil)
        let primary = CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        let muted = CGColor(red: 0.32, green: 0.32, blue: 0.32, alpha: 1)
        let error = CGColor(red: 0.72, green: 0.08, blue: 0.08, alpha: 1)
        let commandBackground = CGColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1)
        let fallback = CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary)

        return CodexTrajectoryTheme(
            identifier: "default-light-\(textSize)-\(monospacedSize)",
            stylesByKind: [
                .userText: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary),
                .assistantText: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary),
                .commandOutput: CodexTrajectoryBlockStyle(
                    font: monospacedFont,
                    foregroundColor: primary,
                    backgroundColor: commandBackground
                ),
                .toolCall: CodexTrajectoryBlockStyle(font: monospacedFont, foregroundColor: muted),
                .fileChange: CodexTrajectoryBlockStyle(font: monospacedFont, foregroundColor: primary),
                .approvalRequest: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary),
                .status: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: muted),
                .warning: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary),
                .stderr: CodexTrajectoryBlockStyle(font: monospacedFont, foregroundColor: error),
                .systemEvent: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: muted),
            ],
            fallbackStyle: fallback
        )
    }
}
