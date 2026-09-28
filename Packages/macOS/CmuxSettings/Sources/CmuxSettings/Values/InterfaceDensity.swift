import Foundation

/// How much room cmux's window controls take: the titlebar buttons, the
/// sidebar footer, and the pane tab bar's action buttons.
///
/// Sidebar row detail has its own setting (`sidebar.*` toggles); this one
/// only sizes and folds controls. Text size is `app.globalFontMagnification`.
public enum InterfaceDensity: String, CaseIterable, Sendable, SettingCodable {
    /// Larger icons and hit targets, closer to the macOS 28pt control default.
    case comfortable
    /// The sizes cmux shipped before this setting existed.
    case standard
    /// Smaller icons that stay at or above the 20pt macOS minimum hit target,
    /// with action buttons folded behind hover until the pointer reaches them.
    case compact

    /// UserDefaults key storing the raw value.
    public static let userDefaultsKey = "interfaceDensity"

    /// Density used when nothing is stored. `standard` is the set cmux
    /// shipped before this setting, so upgrading changes nothing until the
    /// setting is chosen.
    public static let defaultValue: InterfaceDensity = .standard

    /// Reads the stored density, falling back to ``defaultValue`` for a
    /// missing or unrecognized value.
    ///
    /// Reads the key directly instead of building `AppCatalogSection`, since
    /// titlebar hit testing calls this on pointer events.
    public static func stored(in defaults: UserDefaults = .standard) -> InterfaceDensity {
        InterfaceDensity(rawValue: defaults.string(forKey: userDefaultsKey) ?? "") ?? defaultValue
    }

    /// Whether secondary action buttons stay hidden until hovered.
    public var foldsActionsBehindHover: Bool {
        self == .compact
    }
}
