public import Foundation

/// A snapshot of the macOS system interface style (light or dark), read from the
/// `AppleInterfaceStyle` user-defaults key.
///
/// This is the pure, terminal-domain home of the value the app's appearance
/// layer used to own. It reads the same frozen system defaults key the terminal
/// color-scheme resolution has always used, so config-time theme selection no
/// longer reaches up into the app's appearance settings type.
public struct TerminalSystemAppearance: Equatable, Sendable {
    /// The raw `AppleInterfaceStyle` value (for example `"Dark"`), or `nil` when
    /// the system is in light mode and the key is unset.
    public let interfaceStyle: String?

    /// The system defaults key macOS sets to `"Dark"` while dark mode is active.
    public static let appleInterfaceStyleKey = "AppleInterfaceStyle"

    /// The `AppleInterfaceStyle` value that indicates dark mode.
    public static let darkInterfaceStyleValue = "Dark"

    /// Creates a system-appearance snapshot from a raw interface-style value.
    public init(interfaceStyle: String?) {
        self.interfaceStyle = interfaceStyle
    }

    /// Whether the system is currently in dark mode.
    public var prefersDark: Bool {
        interfaceStyle?.caseInsensitiveCompare(Self.darkInterfaceStyleValue) == .orderedSame
    }

    /// Reads the current system appearance from the given defaults, falling back
    /// to the global domain so the value is correct even when the app's own
    /// suite has not mirrored `AppleInterfaceStyle`.
    public static func current(defaults: UserDefaults = .standard) -> TerminalSystemAppearance {
        let directValue = defaults.string(forKey: appleInterfaceStyleKey)
        let globalValue = defaults
            .persistentDomain(forName: UserDefaults.globalDomain)?[appleInterfaceStyleKey] as? String
        return TerminalSystemAppearance(interfaceStyle: directValue ?? globalValue)
    }
}
