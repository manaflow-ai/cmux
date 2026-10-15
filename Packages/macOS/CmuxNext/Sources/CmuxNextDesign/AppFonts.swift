public import AppKit

/// The app's own type faces (`appearance.fonts.*` in cmux.json, `AppFontsSetting`): the face of
/// text in chrome and pages, the face of code, and the chat's text size. All unset is today's look:
/// the system face, each surface's own monospaced face (or the terminal's, `codeFamily`), 14 px.
///
/// Pages read them as CSS variables (``cssVariables``, sent with every theme by
/// `WebTheme`); native chrome reads ``design`` through `Typography.system`.
public nonisolated struct AppFonts: Equatable, Sendable {
    /// A system face design for text: the system font itself, or its rounded, serif or monospaced
    /// design (SF Pro Rounded, New York, SF Mono), which every Mac has and WebKit names as
    /// `ui-rounded`, `ui-serif` and `ui-monospace`.
    public nonisolated enum Design: String, CaseIterable, Sendable {
        case system, rounded, serif, mono

        /// The AppKit design (`NSFontDescriptor.SystemDesign`); nil for the plain system font.
        public var systemDesign: NSFontDescriptor.SystemDesign? {
            switch self {
            case .system: nil
            case .rounded: .rounded
            case .serif: .serif
            case .mono: .monospaced
            }
        }

        /// The CSS family list pages draw text in; nil for the system face (each page's own stack).
        var css: String? {
            switch self {
            case .system: nil
            case .rounded: "ui-rounded, -apple-system, system-ui, sans-serif"
            case .serif: "ui-serif, \"New York\", Georgia, serif"
            case .mono: "ui-monospace, \"SF Mono\", Menlo, monospace"
            }
        }
    }

    public static let chatSizeRange: ClosedRange<Double> = 11...20
    public static let defaultChatSize: Double = 14

    /// Text in chrome and pages (`appearance.fonts.ui`).
    public var design: Design
    /// Code (`appearance.fonts.code`); nil follows the terminal's face.
    public var code: String?
    /// The chat's text size in points (`appearance.fonts.chatSize`); nil is 14.
    public var chatSize: Double?

    public init(design: Design = .system, code: String? = nil, chatSize: Double? = nil) {
        (self.design, self.code, self.chatSize) = (design, code, chatSize)
    }

    /// The family code draws in: the chosen one, else the terminal's (`terminalFamily`), else nil
    /// (each surface's own monospaced default).
    public func codeFamily(terminalFamily: String?) -> String? { code ?? terminalFamily }

    /// `--cmux-font-ui`, `--cmux-font-code` and `--cmux-font-chat-size` for pages. An unset one is
    /// `initial` (guaranteed-invalid), so each page's `var(--cmux-font-*, <its own>)` keeps its look:
    /// an unset code face leaves the chat its own monospaced face, while pages that already draw
    /// code in the terminal's face read ``codeFamily(terminalFamily:)`` (`WebTheme.codeFontFamily`).
    public var cssVariables: [String: String] {
        let code = self.code.map { "\(Self.quoted($0)), ui-monospace, \"SF Mono\", Menlo, monospace" }
        let size = chatSize.map { size in
            let points = (size * 100).rounded() / 100
            return points == points.rounded() ? "\(Int(points))px" : "\(points)px"
        }
        return ["--cmux-font-ui": design.css ?? "initial", "--cmux-font-code": code ?? "initial",
                "--cmux-font-chat-size": size ?? "initial"]
    }

    /// `family` as a CSS string (double quotes, `\` and `"` escaped).
    static func quoted(_ family: String) -> String {
        "\"" + family.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
