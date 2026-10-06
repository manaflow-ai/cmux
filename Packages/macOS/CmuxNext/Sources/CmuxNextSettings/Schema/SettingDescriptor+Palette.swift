public import CmuxNextDesign
import Foundation

/// One value the palette offers for a setting (R93): `value` nil resets the
/// key to its default. A color carries its swatch (R98).
public nonisolated struct SettingOption: Hashable, Sendable {
    public let value: JSONValue?
    public let title: String
    public let swatches: [ThemeRGB]
    public let isCurrent: Bool

    public init(value: JSONValue?, title: String, swatches: [ThemeRGB] = [], isCurrent: Bool) {
        self.value = value
        self.title = title
        self.swatches = swatches
        self.isCurrent = isCurrent
    }

    /// A stable id for the palette row: the compact JSON text, or "reset".
    public var id: String { value?.compactText ?? "reset" }
}

extension SettingDescriptor {
    /// Most values a number lists; a wider range is sampled on its step grid.
    static let maximumNumberOptions = 41

    /// The values the palette lists for this setting, the current one marked:
    /// a toggle's on and off, a choice's values, a number's steps (the
    /// default first), a color's theme colors as swatches (the theme default
    /// first). Kinds with free text (fonts, sounds, addresses, hosts, times)
    /// list nothing; the palette types them.
    public func paletteOptions(current: JSONValue?, themeColors: [ThemeRGB]) -> [SettingOption] {
        let current = current ?? defaultValue
        switch kind {
        case .toggle:
            let on = current?.boolValue ?? false
            return [SettingOption(value: .bool(true), title: SettingsText.text("settings.choice.on", "On"), isCurrent: on),
                    SettingOption(value: .bool(false), title: SettingsText.text("settings.choice.off", "Off"), isCurrent: !on)]
        case .choice(let choices), .choiceOrNumber(let choices, _):
            return choices.map { SettingOption(value: .string($0.value), title: $0.title, isCurrent: current?.stringValue == $0.value) }
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
        case .sound, .url, .hostList, .folderList, .timeRange, .theme, .fontFamily, .numberList, .stringMap, .stringList:
            return []
        }
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
        case .seconds: return String(format: SettingsText.text("settings.value.seconds", "%@ s"), number)
        case .minutes: return String(format: SettingsText.text("settings.value.minutes", "%@ min"), number)
        case .count, .fraction: return number
        }
    }
}
