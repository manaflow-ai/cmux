import CmuxNextActions
public import CmuxNextDesign
import Foundation

/// One value the palette offers for a setting (R93): `value` nil resets the
/// key to its default. A color carries its swatch (R98); a font picked lately says so (`RecentFonts`).
public nonisolated struct SettingOption: Hashable, Sendable {
    public let value: JSONValue?
    public let title: String
    public let swatches: [ThemeRGB]
    public let isCurrent: Bool
    public let isRecent: Bool

    public init(value: JSONValue?, title: String, swatches: [ThemeRGB] = [], isCurrent: Bool, isRecent: Bool = false) {
        self.value = value
        self.title = title
        self.swatches = swatches
        self.isCurrent = isCurrent
        self.isRecent = isRecent
    }

    /// A stable id for the palette row: the compact JSON text, or "reset".
    public var id: String { value?.compactText ?? "reset" }

    /// The value behind an option id (`SettingOption.id`): "reset" is nil.
    public static func value(_ option: String) -> JSONValue? {
        guard option != "reset" else { return nil }
        return (try? JSONValue.parse(Data(option.utf8))) ?? .string(option)
    }

    /// A theme setting's values (R98): the Ghostty config (reset) first,
    /// onboarding's themes, then every other theme in `names`, each with its
    /// swatch strip from `strip`; a current value not listed (a light/dark
    /// pair, a path) is kept after the config row.
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

/// What the palette lists for a row is Rust's (`schema.typed`, `schema.inherited`,
/// `schema.palette_options`): these read it through ``SettingsRust`` and render its titles in the
/// app's language (the string catalog, Foundation's number formats) and its swatches.
extension SettingDescriptor {
    /// The JSON value for typed text (a number off the steps, a hex color, a font, a sound, an
    /// address), when the schema accepts it.
    public func value(typed text: String) -> JSONValue? {
        Self.present(SettingsRust.answer("schema.typed", ["key": .string(id), "text": .string(text)])["value"])
    }

    /// The values the palette lists for this setting, the current one marked:
    /// a toggle's on and off, a choice's values, a number's steps (the
    /// default first), a color's theme colors as swatches (the theme default
    /// first), a list of what shows as rows that toggle, a full order as rows
    /// that move a choice to the front (starting from `inherited` while the key
    /// has no value: ``inheritedValue(in:)``). Kinds with free text (fonts,
    /// sounds, addresses, hosts, times) list nothing; the palette types them.
    public func paletteOptions(current: JSONValue?, inherited: JSONValue? = nil, themeColors: [ThemeRGB]) -> [SettingOption] {
        options(in: paletteReply(current: current, inherited: inherited, themeColors: themeColors), themeColors: themeColors)
    }

    /// ``paletteOptions(current:inherited:themeColors:)`` for a row read with the palette in one batch
    /// (``SettingsSchema/reads(root:storedRoot:keys:palette:)`` with the same `themeColors`).
    public func paletteOptions(_ read: SettingRowRead, themeColors: [ThemeRGB]) -> [SettingOption] {
        options(in: read.palette ?? .object([:]), themeColors: themeColors)
    }

    /// ``paletteSummary(current:options:)`` for a row read with the palette in one batch.
    public func paletteSummary(_ read: SettingRowRead, options: [SettingOption]) -> String? {
        if options.contains(where: { $0.value == nil && $0.isCurrent }) { return nil }
        guard let titles = read.palette?["summary"]?.arrayValue else { return nil }
        return titles.map { localized($0) }.joined(separator: ", ")
    }

    /// The options of a `schema.palette_options` reply, with their titles in the app's language.
    private func options(in reply: JSONValue, themeColors: [ThemeRGB]) -> [SettingOption] {
        (reply["options"]?.arrayValue ?? []).map { option in
            let swatches: [ThemeRGB] = if let index = option["swatch"]?["theme"]?.intValue, themeColors.indices.contains(index) {
                [themeColors[index]]
            } else if let hex = option["swatch"]?["hex"]?.stringValue, let color = ThemeRGB(cssHex: hex) {
                [color]
            } else {
                []
            }
            return SettingOption(value: option["value"], title: optionTitle(option["title"]), swatches: swatches,
                                 isCurrent: option["current"]?.boolValue ?? false)
        }
    }

    /// The value a row with no value of its own goes by, read from `root`: a per-kind second-line
    /// order (`sidebar.workspaceRow.terminal.secondLineOrder`) follows All Workspaces'. Nil for
    /// every other row.
    public func inheritedValue(in root: JSONValue) -> JSONValue? {
        Self.present(SettingsRust.answer("schema.inherited", ["key": .string(id), "root": root])["value"])
    }

    /// The palette row's value text for a list of choices; nil for any other kind, and for a key
    /// left unset (the unset row's title says it). A list of what shows names the choices it
    /// holds, or None; a full order names every choice in the order that applies.
    public func paletteSummary(current: JSONValue?, options: [SettingOption]) -> String? {
        if options.contains(where: { $0.value == nil && $0.isCurrent }) { return nil }
        guard let titles = paletteReply(current: current, inherited: nil, themeColors: [])["summary"]?.arrayValue else { return nil }
        return titles.map { localized($0) }.joined(separator: ", ")
    }

    /// `schema.palette_options`' reply, asked again with the background the app resolves when
    /// Rust names a value it does not list (a retired painting, your own image, a wallpaper).
    private func paletteReply(current: JSONValue?, inherited: JSONValue?, themeColors: [ThemeRGB]) -> JSONValue {
        var request: [String: JSONValue] = [
            "key": .string(id), "current": current ?? .null, "inherited": inherited ?? .null,
            "theme_colors": .array(themeColors.map(\.rustRequest)),
        ]
        let reply = SettingsRust.answer("schema.palette_options", .object(request))
        guard let raw = reply["need"]?["selection"]?.stringValue else { return reply }
        request["selection"] = BackdropSelection(id: raw).map { ["id": .string($0.id), "title": .string($0.title)] } ?? .null
        return SettingsRust.answer("schema.palette_options", .object(request))
    }

    /// An option's title in the app's language: a catalog text, a number Foundation formats, or
    /// a format with one argument (`Move %@ to Front`).
    private func optionTitle(_ title: JSONValue?) -> String {
        if let number = title?["number"]?.doubleValue {
            return Self.format(number, Self.unit(title?["unit"]?.stringValue))
        }
        if let format = title?["format"] {
            return String(format: localized(format), localized(title?["arg"]))
        }
        return localized(title)
    }

    /// A schema text `{text, key}` in the app's language. The row's own texts (its choices, its
    /// default label) are localized already; the palette's fixed words come from the catalog;
    /// a text with no key (a product name, your own image's name) is shown as it is.
    private func localized(_ text: JSONValue?) -> String {
        let english = text?["text"]?.stringValue ?? ""
        guard let key = text?["key"]?.stringValue else { return english }
        if key == textKeys.defaultLabel, let defaultLabel { return defaultLabel }
        if let choice = kindChoices.first(where: { $0.titleKey == key }) { return choice.title }
        return switch key {
        case "settings.choice.on": SettingsText.text("settings.choice.on", "On")
        case "settings.choice.off": SettingsText.text("settings.choice.off", "Off")
        case "settings.choice.default": SettingsText.text("settings.choice.default", "Default")
        case "settings.choice.none": SettingsText.text("settings.choice.none", "None")
        case "settings.default.theme": SettingsText.text("settings.default.theme", "Theme")
        case "settings.palette.moveToFront": SettingsText.text("settings.palette.moveToFront", "Move %@ to Front")
        default: english
        }
    }

    /// The choices of a choice kind, whose titles a palette text can name.
    private var kindChoices: [SettingChoice] {
        switch kind {
        case .choice(let choices), .choiceOrNumber(let choices, _), .choiceOrURL(let choices, _),
             .orderedChoices(let choices), .choiceSet(let choices):
            choices
        default:
            []
        }
    }

    /// The schema's unit name (`points`, `milliseconds`, ...) as ``SettingNumber/Unit``.
    private static func unit(_ name: String?) -> SettingNumber.Unit {
        switch name {
        case "points": .points
        case "milliseconds": .milliseconds
        case "seconds": .seconds
        case "minutes": .minutes
        case "days": .days
        case "fraction": .fraction
        default: .count
        }
    }

    static func format(_ value: Double, _ unit: SettingNumber.Unit) -> String {
        if unit == .fraction {
            return value.formatted(.percent.precision(.fractionLength(0...1)))
        }
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        switch unit {
        case .points: return String(format: SettingsText.text("settings.value.points", "%@ pt"), number)
        // "1,300 ms", localized by Foundation.
        case .milliseconds: return Measurement(value: value, unit: UnitDuration.milliseconds).formatted(.measurement(width: .abbreviated))
        case .seconds: return String(format: SettingsText.text("settings.value.seconds", "%@ s"), number)
        case .minutes: return String(format: SettingsText.text("settings.value.minutes", "%@ min"), number)
        case .days: return days(Int(value.rounded())) ?? number
        case .count, .fraction: return number
        }
    }

    /// "30 days", localized by Foundation.
    private static func days(_ count: Int) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day]
        formatter.unitsStyle = .full
        return formatter.string(from: DateComponents(day: count))
    }
}
