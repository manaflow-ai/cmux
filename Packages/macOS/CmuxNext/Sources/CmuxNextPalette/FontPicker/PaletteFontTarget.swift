import Foundation

/// One surface the font picker sets a font for: its family setting (a font family or a choice of
/// faces) and, where the surface has them, its size and line height settings. The picker shows a
/// target's families as rows drawn in their own face and its size and line height as sliders.
public struct PaletteFontTarget: Identifiable {
    public let id: String
    public let title: String
    public let family: PaletteSettingRow
    public let size: PaletteSettingRow?
    public let lineHeight: PaletteSettingRow?
    /// What the sample under the list shows: code for a code font, prose for a reading font.
    public let sample: PaletteFontSample

    public var familyOptions: [PaletteSettingOption] {
        guard case .options(let options, _) = family.kind else { return [] }
        return options
    }

    /// The setting rows this target writes.
    public var rowIDs: [String] { [family.id] + [size, lineHeight].compactMap { $0?.id } }
}

/// The text a target's sample draws.
public enum PaletteFontSample: Sendable {
    case code
    case prose
}

/// The font picker's targets, in the order the target strip shows them, made from the settings
/// rows the source lists: a target whose family row the source does not list (a setting that does
/// not exist yet, or a managed one) is left out, and so is a size or line height row it lacks. A new
/// family setting joins by one line here.
public enum PaletteFontTargets {
    struct Spec {
        var id: String
        var title: @Sendable () -> String
        var family: String
        var size: String?
        var lineHeight: String?
        var sample: PaletteFontSample
    }

    static let specs: [Spec] = [
        Spec(id: "terminal", title: { PaletteStrings.fontTargetTerminal }, family: "terminal.fontFamily",
             size: "terminal.fontSize", lineHeight: "terminal.lineHeight", sample: .code),
        Spec(id: "app", title: { PaletteStrings.fontTargetApp }, family: "appearance.font",
             size: "appearance.metrics.chromeFontSize", lineHeight: nil, sample: .prose),
        Spec(id: "editor", title: { PaletteStrings.fontTargetEditor }, family: "editor.fontFamily",
             size: "editor.fontSize", lineHeight: nil, sample: .code),
        Spec(id: "chat", title: { PaletteStrings.fontTargetChat }, family: "agentPane.display.font.ui",
             size: "agentPane.display.font.size", lineHeight: "agentPane.display.font.lineHeight", sample: .prose),
        Spec(id: "chatCode", title: { PaletteStrings.fontTargetChatCode }, family: "agentPane.display.code.family",
             size: nil, lineHeight: nil, sample: .code),
        Spec(id: "markdown", title: { PaletteStrings.fontTargetMarkdown }, family: "markdown.font.preset",
             size: "markdown.font.size", lineHeight: "markdown.font.lineHeight", sample: .prose),
        Spec(id: "markdownCode", title: { PaletteStrings.fontTargetMarkdownCode }, family: "markdown.code.family",
             size: nil, lineHeight: nil, sample: .code),
    ]

    /// The targets `rows` make (enabled rows only: a managed family cannot be picked).
    public static func targets(from rows: [PaletteSettingRow]) -> [PaletteFontTarget] {
        let byID = Dictionary(rows.filter(\.isEnabled).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return specs.compactMap { spec in
            guard let family = byID[spec.family], case .options = family.kind else { return nil }
            return PaletteFontTarget(
                id: spec.id, title: spec.title(), family: family,
                size: spec.size.flatMap { byID[$0] }.flatMap { $0.number == nil ? nil : $0 },
                lineHeight: spec.lineHeight.flatMap { byID[$0] }.flatMap { $0.number == nil ? nil : $0 },
                sample: spec.sample
            )
        }
    }

    /// Every row id a target may write: Change Font… stands for these rows in the Settings scope.
    public static var rowIDs: Set<String> {
        Set(specs.flatMap { [$0.family, $0.size, $0.lineHeight].compactMap { $0 } })
    }
}
