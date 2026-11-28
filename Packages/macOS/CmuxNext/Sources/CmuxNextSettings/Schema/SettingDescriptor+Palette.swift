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

extension SettingDescriptor {
    /// Most values a number lists; a wider range is sampled on its step grid.
    static let maximumNumberOptions = 41

    /// The JSON value for typed text (a number off the steps, a hex color, a font, a sound, an
    /// address), when the schema accepts it.
    public func value(typed text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let candidate: JSONValue = switch kind {
        case .number, .choiceOrNumber: Double(trimmed).map(JSONValue.number) ?? .string(trimmed)
        // A typed address is the object form (`{"selfHosted": url}`); a choice stays its string.
        case .choiceOrURL(let choices, let urlKey):
            choices.contains { $0.value == trimmed } ? .string(trimmed) : .object([urlKey: .string(trimmed)])
        default: .string(trimmed)
        }
        return accepts(candidate) ? candidate : nil
    }

    /// The values the palette lists for this setting, the current one marked:
    /// a toggle's on and off, a choice's values, a number's steps (the
    /// default first), a color's theme colors as swatches (the theme default
    /// first), a list of what shows as rows that toggle (`pickedListOptions`),
    /// a full order as rows that move a choice to the front (`orderOptions`,
    /// starting from `inherited` while the key has no value: ``inheritedValue(in:)``).
    /// Kinds with free text (fonts, sounds, addresses, hosts, times) list
    /// nothing; the palette types them.
    public func paletteOptions(current: JSONValue?, inherited: JSONValue? = nil, themeColors: [ThemeRGB]) -> [SettingOption] {
        let current = current ?? defaultValue
        switch kind {
        case .toggle:
            let on = current?.boolValue ?? false
            return [SettingOption(value: .bool(true), title: SettingsText.text("settings.choice.on", "On"), isCurrent: on),
                    SettingOption(value: .bool(false), title: SettingsText.text("settings.choice.off", "Off"), isCurrent: !on)]
        case .choiceOrNumber(let choices, _) where defaultValue == nil:
            // Unset is a value of its own (`browser.hibernation`: never discard): listed first, it
            // removes the key.
            let unset = SettingOption(value: nil, title: defaultLabel ?? SettingsText.text("settings.choice.default", "Default"),
                                      isCurrent: current == nil)
            return [unset] + choices.map { SettingOption(value: .string($0.value), title: $0.title, isCurrent: current?.stringValue == $0.value) }
        case .choice(let choices), .choiceOrNumber(let choices, _), .choiceOrURL(let choices, _):
            let options = choices.map { SettingOption(value: .string($0.value), title: $0.title, isCurrent: current?.stringValue == $0.value) }
            return path == BackdropSelectionSetting.configPath ? Self.backgroundOptions(options, current: current) : options
        case .number(let number):
            var options: [SettingOption] = []
            if defaultValue == nil {
                options.append(SettingOption(value: nil, title: defaultLabel ?? SettingsText.text("settings.choice.default", "Default"),
                                             isCurrent: current == nil))
            }
            let selected = current?.doubleValue
            options += Self.numberValues(number, including: selected).map { value in
                SettingOption(value: .number(value), title: Self.format(value, number.unit), isCurrent: selected == value)
            }
            return options
        case .color:
            let selected = current?.stringValue.flatMap { ThemeRGB(cssHex: $0) }
            var options = [SettingOption(value: nil, title: defaultLabel ?? SettingsText.text("settings.default.theme", "Theme"),
                                         isCurrent: selected == nil)]
            var seen = Set<String>()
            for color in themeColors where seen.insert(Self.hex(color)).inserted {
                options.append(SettingOption(value: .string(Self.hex(color)), title: Self.hex(color), swatches: [color],
                                             isCurrent: selected.map(Self.hex) == Self.hex(color)))
            }
            if let selected, !seen.contains(Self.hex(selected)) {
                let text = current?.stringValue ?? Self.hex(selected)
                options.append(SettingOption(value: .string(text), title: text, swatches: [selected], isCurrent: true))
            }
            return options
        case .choiceSet(let choices):
            return pickedListOptions(choices, current: current, ordered: false)
        case .orderedChoices(let choices) where orderedChoicesHideOmitted:
            return pickedListOptions(choices, current: current, ordered: true)
        case .orderedChoices(let choices):
            return orderOptions(choices, current: current, inherited: inherited)
        case .sound, .url, .hostList, .folderList, .timeRange, .theme, .fontFamily, .text, .numberList, .stringMap, .soundRules, .stringList, .json:
            return []
        }
    }

    /// An `orderedChoices` row whose list holds only what shows, so a choice it leaves out is
    /// hidden: `tabs.toolbarButtons` (``PaneToolbarButtonsSetting``, the pinned buttons, toggled
    /// from the tab bar's More menu). Every other ordered list is a full order: a choice it leaves
    /// out still shows, after the listed ones in the default order (`sidebar.workspaceRow.
    /// secondLineOrder`, read by `WorkspaceRowElements.completeOrder`; the Settings page's order
    /// editor writes all of it), and its visibility is a setting of its own.
    var orderedChoicesHideOmitted: Bool { path == PaneToolbarButtonsSetting.configPath }

    /// The value a row with no value of its own goes by, read from `root`: a per-kind second-line
    /// order (`sidebar.workspaceRow.terminal.secondLineOrder`) follows All Workspaces'. Nil for
    /// every other row.
    public func inheritedValue(in root: JSONValue) -> JSONValue? {
        guard let from = WorkspaceRowSetting.inheritedOrderPath(for: path) else { return nil }
        return SettingsSchema.descriptor(for: from)?.effectiveValue(in: root)
    }

    /// The row that unsets a key with no default (a per-kind override: Same as All Workspaces),
    /// listed first; nil for a row with a default.
    private func unsetOption(current: JSONValue?) -> SettingOption? {
        guard defaultValue == nil else { return nil }
        return SettingOption(value: nil, title: defaultLabel ?? SettingsText.text("settings.choice.default", "Default"),
                             isCurrent: current == nil)
    }

    /// The stored values that are choices, first occurrence only, in the stored order.
    private static func storedChoices(_ choices: [SettingChoice], _ value: JSONValue?) -> [String] {
        var stored: [String] = []
        if case .array(let items)? = value {
            for case .string(let item) in items where choices.contains(where: { $0.value == item }) && !stored.contains(item) {
                stored.append(item)
            }
        }
        return stored
    }

    /// The order that applies: the stored choices, then the ones left out in the choices' order
    /// (the Settings page's `orderedChoiceValues`, `WorkspaceRowElements.completeOrder`).
    static func effectiveOrder(_ choices: [SettingChoice], _ value: JSONValue?) -> [String] {
        let stored = storedChoices(choices, value)
        return stored + choices.map(\.value).filter { !stored.contains($0) }
    }

    /// A list of what shows (`choiceSet`, `tabs.toolbarButtons`): one row per choice, checked while
    /// the list holds it, whose value is the list with that choice toggled. A choice set keeps the
    /// choices' order (the Settings page's switches write it the same way); an ordered one lists
    /// its stored order first, adds a choice at the end and removes one in place.
    private func pickedListOptions(_ choices: [SettingChoice], current: JSONValue?, ordered: Bool) -> [SettingOption] {
        let stored = Self.storedChoices(choices, current)
        let rows = ordered
            ? stored.compactMap { item in choices.first { $0.value == item } } + choices.filter { !stored.contains($0.value) }
            : choices
        return [unsetOption(current: current)].compactMap { $0 } + rows.map { (choice: SettingChoice) -> SettingOption in
            let isOn = stored.contains(choice.value)
            let next: [String] = if ordered {
                isOn ? stored.filter { $0 != choice.value } : stored + [choice.value]
            } else {
                choices.map(\.value).filter { $0 == choice.value ? !isOn : stored.contains($0) }
            }
            return SettingOption(value: .array(next.map(JSONValue.string)), title: choice.title, isCurrent: isOn)
        }
    }

    /// A full order (`sidebar.workspaceRow.secondLineOrder`): every choice once, in the order that
    /// applies, unchecked; each row moves its choice to the front and writes the whole order, so
    /// nothing is dropped and the rest keep their places. A key with no value of its own starts
    /// from what it goes by (`inherited`: All Workspaces' order), then the choices' order; never a
    /// partial or empty list. Up and down moves stay on the Settings page.
    private func orderOptions(_ choices: [SettingChoice], current: JSONValue?, inherited: JSONValue?) -> [SettingOption] {
        let order = Self.effectiveOrder(choices, current ?? inherited)
        let titles = Dictionary(choices.map { ($0.value, $0.title) }, uniquingKeysWith: { first, _ in first })
        return [unsetOption(current: current)].compactMap { $0 } + order.map { (item: String) -> SettingOption in
            let moved = [item] + order.filter { $0 != item }
            let title = String(format: SettingsText.text("settings.palette.moveToFront", "Move %@ to Front"), titles[item] ?? item)
            return SettingOption(value: .array(moved.map(JSONValue.string)), title: title, isCurrent: false)
        }
    }

    /// The palette row's value text for a list of choices; nil for any other kind, and for a key
    /// left unset (the unset row's title says it). A list of what shows names the choices it
    /// holds, or None; a full order names every choice in the order that applies.
    public func paletteSummary(current: JSONValue?, options: [SettingOption]) -> String? {
        if options.contains(where: { $0.value == nil && $0.isCurrent }) { return nil }
        switch kind {
        case .orderedChoices(let choices) where !orderedChoicesHideOmitted:
            let titles = Dictionary(choices.map { ($0.value, $0.title) }, uniquingKeysWith: { first, _ in first })
            return Self.effectiveOrder(choices, current ?? defaultValue).map { titles[$0] ?? $0 }.joined(separator: ", ")
        case .choiceSet, .orderedChoices:
            let titles = options.filter { $0.value != nil && $0.isCurrent }.map(\.title)
            return titles.isEmpty ? SettingsText.text("settings.choice.none", "None") : titles.joined(separator: ", ")
        default:
            return nil
        }
    }

    /// `appearance.background`'s options, naming what the window shows when the value is not one
    /// the list offers: a retired painting id marks the work that replaced it, and your own image
    /// or a macOS wallpaper is one more option, current, by its name.
    static func backgroundOptions(_ options: [SettingOption], current: JSONValue?) -> [SettingOption] {
        guard !options.contains(where: \.isCurrent), let raw = current?.stringValue, let selection = BackdropSelection(id: raw) else {
            return options
        }
        let shown = JSONValue.string(selection.id)
        if options.contains(where: { $0.value == shown }) {
            return options.map { SettingOption(value: $0.value, title: $0.title, swatches: $0.swatches, isCurrent: $0.value == shown) }
        }
        return options + [SettingOption(value: .string(raw), title: selection.title, isCurrent: true)]
    }

    /// Every step from the low end to the high end, or, for a wider range,
    /// both ends, `including` and evenly spread steps (all on the grid).
    static func numberValues(_ number: SettingNumber, including value: Double?) -> [Double] {
        let low = number.range.lowerBound, high = number.range.upperBound
        let count = Int(((high - low) / number.step).rounded(.down)) + 1
        let onGrid = { (index: Int) in min(high, low + Double(index) * number.step) }
        var values: Set<Double>
        if count <= maximumNumberOptions {
            values = Set((0..<count).map(onGrid))
        } else {
            let slots = maximumNumberOptions - 3
            values = Set((0...slots).map { onGrid(Int((Double($0) * Double(count - 1) / Double(slots)).rounded())) })
        }
        values.insert(high)
        if let value, number.range.contains(value) { values.insert(value) }
        return values.sorted()
    }

    /// `#RRGGBB` (or `#RRGGBBAA` for a translucent color), as cmux-next.json stores it.
    static func hex(_ color: ThemeRGB) -> String {
        let byte = { (value: Double) in Int((value * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
        return color.alpha < 1 ? rgb + String(format: "%02X", byte(color.alpha)) : rgb
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
