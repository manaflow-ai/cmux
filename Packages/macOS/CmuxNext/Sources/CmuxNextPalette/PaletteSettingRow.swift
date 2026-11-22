public import CmuxNextDesign

/// One value in a setting's palette list. `swatches` draws real colors in
/// the row's icon place (R98).
public struct PaletteSettingOption: Identifiable, Sendable {
    public let id: String
    public var title: String
    public var swatches: [ThemeRGB]
    public var isCurrent: Bool

    public init(id: String, title: String, swatches: [ThemeRGB] = [], isCurrent: Bool = false) {
        self.id = id
        self.title = title
        self.swatches = swatches
        self.isCurrent = isCurrent
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
        /// Flips in place.
        case toggle(isOn: Bool)
        /// A value list: a choice, a number's steps, a color's swatches.
        /// Moving the highlight previews; Return commits; leaving reverts.
        case options([PaletteSettingOption], customInput: PaletteSettingCustomInput? = nil)
    }

    public let id: String
    public var title: String
    /// The Settings group (shown after the title).
    public var group: String
    /// The current value, as the row's accessory.
    public var value: String
    public var kind: Kind
    public var keywords: [String]
    /// The swatch of the current value (a color setting).
    public var swatches: [ThemeRGB]
    /// False for a managed key: shown, but it does not run.
    public var isEnabled: Bool

    public init(id: String, title: String, group: String, value: String, kind: Kind, keywords: [String] = [],
                swatches: [ThemeRGB] = [], isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.group = group
        self.value = value
        self.kind = kind
        self.keywords = keywords
        self.swatches = swatches
        self.isEnabled = isEnabled
    }
}
