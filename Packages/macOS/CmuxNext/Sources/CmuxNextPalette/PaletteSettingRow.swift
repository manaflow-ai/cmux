public import CmuxNextDesign

/// One value in a setting's palette list. `swatches` draws real colors in
/// the row's icon place (R98); `fontFamily` draws the title in that face (a
/// font family setting's values).
public struct PaletteSettingOption: Identifiable, Sendable {
    public let id: String
    public var title: String
    public var swatches: [ThemeRGB]
    public var isCurrent: Bool
    public var fontFamily: String?
    /// A font picked lately (`RecentFonts`): its row says Recent.
    public var isRecent: Bool

    public init(id: String, title: String, swatches: [ThemeRGB] = [], isCurrent: Bool = false,
                fontFamily: String? = nil, isRecent: Bool = false) {
        self.id = id
        self.title = title
        self.swatches = swatches
        self.isCurrent = isCurrent
        self.fontFamily = fontFamily
        self.isRecent = isRecent
    }
}

/// Free text for a value no list holds (a hex color, a font, an address).
public struct PaletteSettingCustomInput {
    public var placeholder: String
    public var isValid: @MainActor (String) -> Bool

    public init(placeholder: String, isValid: @escaping @MainActor (String) -> Bool) {
        self.placeholder = placeholder
        self.isValid = isValid
    }
}

/// One setting in the palette (R93): every schema row the source exposes.
public struct PaletteSettingRow: Identifiable {
    public enum Kind {
        /// Flips in place. Shows its state the way every row that flips one does (``PaletteToggleStyle``):
        /// "On" or "Off" at the trailing edge, not `value`.
        case toggle(isOn: Bool)
        /// A value list: a choice, a number's steps, a color's swatches.
        /// Moving the highlight previews; Return commits; leaving reverts.
        case options([PaletteSettingOption], customInput: PaletteSettingCustomInput? = nil)
    }

    public let id: String
    public var title: String
    /// The Settings group (shown after the title).
    public var group: String
    /// The current value, as the row's accessory (an options row; a toggle shows ``PaletteToggleStyle``'s On/Off).
    public var value: String
    public var kind: Kind
    public var keywords: [String]
    /// The swatch of the current value (a color setting).
    public var swatches: [ThemeRGB]
    /// False for a managed key: shown, but it does not run.
    public var isEnabled: Bool
    /// A font family setting: its values are installed fonts (Change Font… lists it).
    public var isFontFamily: Bool
    /// A number setting's range and value, for a slider (the font picker's size and line height).
    public var number: PaletteSettingNumber?

    public init(id: String, title: String, group: String, value: String, kind: Kind, keywords: [String] = [],
                swatches: [ThemeRGB] = [], isEnabled: Bool = true, isFontFamily: Bool = false,
                number: PaletteSettingNumber? = nil) {
        self.id = id
        self.title = title
        self.group = group
        self.value = value
        self.kind = kind
        self.keywords = keywords
        self.swatches = swatches
        self.isEnabled = isEnabled
        self.isFontFamily = isFontFamily
        self.number = number
    }
}

/// A number setting as a slider sees it: its range on its step grid, the value in effect (the
/// stored one, else the default, else `placeholder`) and how a value reads ("13 pt", "160%").
public struct PaletteSettingNumber: Sendable {
    public var range: ClosedRange<Double>
    public var step: Double
    /// The value in effect now.
    public var value: Double
    /// The value an unset key means (nil: derived at run time, such as the Ghostty config's size).
    public var defaultValue: Double?
    public var format: @Sendable (Double) -> String

    public init(range: ClosedRange<Double>, step: Double, value: Double, defaultValue: Double? = nil,
                format: @escaping @Sendable (Double) -> String) {
        self.range = range
        self.step = step
        self.value = value
        self.defaultValue = defaultValue
        self.format = format
    }

    /// `value` clamped to the range and put on the step grid from its low end.
    public func snapped(_ value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let steps = ((clamped - range.lowerBound) / step).rounded()
        // Rounded to the step's own decimals, so 1.2 + 9 * 0.05 is 1.65 and not 1.6500000000000001.
        let snapped = range.lowerBound + steps * step
        return min(range.upperBound, (snapped * 10_000).rounded() / 10_000)
    }
}
