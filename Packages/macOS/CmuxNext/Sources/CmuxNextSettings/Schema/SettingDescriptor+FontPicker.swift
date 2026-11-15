public import CmuxNextDesign
import CmuxNextActions
import Foundation

/// A number setting as a slider (the font picker's size and line height): its range and step, the
/// value now, the default, and how a value reads ("13 pt", "163%").
public nonisolated struct SettingSlider: Sendable {
    public let range: ClosedRange<Double>
    public let step: Double
    public let value: Double
    public let defaultValue: Double?
    public let format: @Sendable (Double) -> String
}

extension SettingDescriptor {
    /// This number setting as a slider at `current` (nil: the default); nil for every other kind.
    public func slider(current: JSONValue?) -> SettingSlider? {
        guard case .number(let number) = kind else { return nil }
        let unit = number.unit
        return SettingSlider(range: number.range, step: number.step,
                             value: current?.doubleValue ?? defaultValue?.doubleValue ?? number.placeholder,
                             defaultValue: defaultValue?.doubleValue, format: { Self.format($0, unit) })
    }

    /// The face a value of this choice of fonts draws in (the chat's interface font, the Markdown
    /// viewer's font), in the font picker. `.system`, `.serif` and `.mono` are the system's own faces;
    /// a face only the web pages bundle draws in the body font there.
    public func optionFace(_ value: String) -> String? {
        Self.optionFaces[id]?[value]
    }

    static let optionFaces: [String: [String: String]] = [
        "agentPane.display.font.ui": [
            "system-ui": ".system", "system-ui-tight": ".system", "inter-tuned": "Inter", "inter": "Inter", "verdana": "Verdana",
            "roboto": "Roboto", "plex": "IBM Plex Sans", "source-sans": "Source Sans 3", "geist": "Geist", "cmux-sans": "cmux Sans",
            "hanken": "Hanken Grotesk", "atkinson": "Atkinson Hyperlegible Next",
        ],
        "markdown.font.preset": ["system": ".system", "serif": ".serif", "mono": ".mono"],
    ]
}

extension SettingOption {
    /// The value behind an option id (``id``): "reset" is nil.
    public static func value(id: String) -> JSONValue? {
        guard id != "reset" else { return nil }
        return (try? JSONValue.parse(Data(id.utf8))) ?? .string(id)
    }

    /// A color setting's swatches from `tokens`: the foreground, the background, then ANSI 0 to 15.
    public static func swatches(of tokens: ThemeTokens) -> [ThemeRGB] {
        [tokens.textPrimary, tokens.windowBackground] + tokens.ansi
    }

    /// A theme setting's values (R98): the Ghostty config (reset) first, onboarding's themes, then
    /// every other theme in `names`, each with its swatch strip from `strip`; a current value not
    /// listed (a light/dark pair, a path) is kept after the config row.
    public static func themeOptions(current: String?, names: [String], defaultLabel: String,
                                    strip: (String) -> [ThemeRGB]) -> [SettingOption] {
        let curated = ActionArgument.curatedThemes.filter(names.contains)
        let listed = curated + names.filter { !curated.contains($0) }
        var options = [SettingOption(value: nil, title: defaultLabel, isCurrent: current == nil)]
        if let current, !listed.contains(current) {
            options.append(SettingOption(value: .string(current), title: current, swatches: strip(current), isCurrent: true))
        }
        options += listed.map { SettingOption(value: .string($0), title: $0, swatches: strip($0), isCurrent: current == $0) }
        return options
    }
}
