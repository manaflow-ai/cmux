import Foundation

/// Settings > Appearance > Personalization (PROTOCOL.md "Appearance", Phone):
/// "Match my Mac" (the default: the Mac most recently connected, else the
/// last stored) or the phone's own choice, from the same options as the
/// Mac's Personalization page: theme, accent, window style, a background
/// picture (from Photos, or none) with its opacity and blur. Stored as JSON
/// in `cmuxMobile.settings.personalization`.
public struct CmuxMobilePersonalization: Codable, Equatable, Sendable {
    public static let settingKey = "cmuxMobile.settings.personalization"

    public enum Mode: String, Codable, Sendable, CaseIterable { case matchMac = "mac", phone }

    public var mode: Mode = .matchMac
    /// A ``CmuxMobileThemeCatalog`` id; `default` is the built-in neutral look.
    public var theme: String = CmuxMobileThemeCatalog.defaultID
    /// `appearance.accent`: `neutral`, `theme`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`.
    public var accent: String = "neutral"
    /// `appearance.chromeStyle`: `default` or `two-tone` (the window styles a phone can show).
    public var chromeStyle: String = "default"
    /// The picture from Photos (its hash in the phone's own image store); nil: none.
    public var background: String?
    public var backgroundOpacity: Double = 1
    public var backgroundBlur: Double = 0

    public init() {}

    public static func load(_ defaults: UserDefaults = .standard) -> CmuxMobilePersonalization {
        guard let data = defaults.data(forKey: settingKey),
              let value = try? JSONDecoder().decode(CmuxMobilePersonalization.self, from: data) else { return .init() }
        return value
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.settingKey)
    }

    /// The accents the Mac offers (`appearance.accent`), in its order.
    public static let accents = ["neutral", "theme", "red", "green", "yellow", "blue", "magenta", "cyan"]
    /// The window styles the phone draws: one surface, or the sidebar a shade apart.
    public static let chromeStyles = ["default", "two-tone"]

    /// The phone's choice as the snapshot a Mac would send, so the phone
    /// derives it with the same code (`cmux-theme-tokens`). Nil: the neutral
    /// look (the default theme with no picture), whose accent is the phone's
    /// Accent color (`CmuxMobileAccentTheme`).
    public func snapshot(backgroundBytes: Int? = nil) -> CmuxMobileAppearanceSnapshot? {
        let entry = CmuxMobileThemeCatalog.entry(theme)
        guard entry.id != CmuxMobileThemeCatalog.defaultID || background != nil else { return nil }
        let pair = entry.id == CmuxMobileThemeCatalog.defaultID ? CmuxMobileThemeCatalog.neutralPair : entry
        return CmuxMobileAppearanceSnapshot(
            revision: 0,
            theme: .init(dark: .init(name: pair.name, input: pair.dark), light: .init(name: pair.name, input: pair.light ?? pair.dark),
                         followsSystem: pair.light != nil),
            accent: accent, chromeStyle: chromeStyle, hue: 0.5, saturation: 1,
            // A picture shows through a quarter of the theme's tint (the Mac's glass default for art).
            glassTransparency: background == nil ? 0 : 0.5,
            sidebarSurface: chromeStyle == "two-tone" ? "separate" : "same",
            background: background.map {
                .init(sha256: $0, bytes: backgroundBytes ?? 0, width: 0, height: 0, opacity: backgroundOpacity, blur: backgroundBlur)
            })
    }
}

/// The themes the phone offers for its own choice: Ghostty themes the Mac
/// ships, as `ThemeInput` (the Mac's whole catalog is its Ghostty theme
/// folder, which the phone does not carry; "Match my Mac" shows any of them).
public enum CmuxMobileThemeCatalog {
    public struct Entry: Sendable, Identifiable, Equatable {
        public let id: String
        public let name: String
        public let dark: CmuxMobileAppearanceSnapshot.Input
        /// The light variant; nil: one theme in both schemes (it holds its own scheme).
        public let light: CmuxMobileAppearanceSnapshot.Input?
    }

    public static let defaultID = "default"

    static func input(_ bg: String, _ fg: String, _ palette: [String], cursor: String? = nil, selection: String? = nil) -> CmuxMobileAppearanceSnapshot.Input {
        .init(background: bg, foreground: fg, palette: palette, selectionBackground: selection, cursor: cursor)
    }

    /// The neutral look as a theme (true black and white), for a picture over the default theme.
    static let neutralPair = Entry(
        id: defaultID, name: "Default",
        dark: input("#000000", "#FFFFFF", []), light: input("#FFFFFF", "#000000", []))

    public static let entries: [Entry] = [
        neutralPair,
        Entry(id: "catppuccin", name: "Catppuccin", dark: mochaInput, light: latteInput),
        Entry(id: "nord", name: "Nord", dark: nordInput, light: nil),
        Entry(id: "dracula", name: "Dracula", dark: input("#282A36", "#F8F8F2",
            ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
             "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"], cursor: "#F8F8F2", selection: "#44475A"),
              light: nil),
        Entry(id: "solarized", name: "Solarized", dark: input("#002B36", "#839496",
            ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
             "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]),
              light: input("#FDF6E3", "#657B83",
            ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
             "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"])),
        Entry(id: "gruvbox", name: "Gruvbox", dark: input("#282828", "#EBDBB2",
            ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
             "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]),
              light: input("#FBF1C7", "#3C3836",
            ["#FBF1C7", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#7C6F64",
             "#928374", "#9D0006", "#79740E", "#B57614", "#076678", "#8F3F71", "#427B58", "#3C3836"])),
        Entry(id: "tokyo-night", name: "Tokyo Night", dark: input("#1A1B26", "#C0CAF5",
            ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
             "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"]),
              light: input("#E1E2E7", "#3760BF",
            ["#E9E9ED", "#F52A65", "#587539", "#8C6C3E", "#2E7DE9", "#9854F1", "#007197", "#6172B0",
             "#A1A6C5", "#F52A65", "#587539", "#8C6C3E", "#2E7DE9", "#9854F1", "#007197", "#3760BF"])),
    ]

    public static func entry(_ id: String) -> Entry {
        entries.first { $0.id == id } ?? neutralPair
    }

    static let mochaInput = input("#1E1E2E", "#CDD6F4",
        ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
         "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"], cursor: "#F5E0DC", selection: "#585B70")
    static let latteInput = input("#EFF1F5", "#4C4F69",
        ["#5C5F77", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#ACB0BE",
         "#6C6F85", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#BCC0CC"], cursor: "#DC8A78", selection: "#ACB0BE")
    static let nordInput = input("#2E3440", "#D8DEE9",
        ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
         "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"], cursor: "#ECEFF4")
}
