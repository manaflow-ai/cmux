/// Selects settings-file values that must replace imported app defaults.
///
/// Unchanged TextBox new-terminal values apply on launch, file edits and
/// explicit reloads. Passive defaults replay and Settings-driven reloads
/// preserve in-session changes by leaving file authority disabled.
///
/// ```swift
/// let policy = SettingsFilePrecedencePolicy()
/// let keys = policy.keysToApply(
///     previous: importedValues,
///     next: fileValues,
///     appliesFileAuthority: true
/// )
/// ```
public struct SettingsFilePrecedencePolicy: Sendable {
    private let authoritativeKeys: Set<String>

    /// Creates the precedence policy from the terminal setting declarations.
    ///
    /// - Parameter terminal: The catalog supplying the persisted terminal keys.
    public init(terminal: TerminalCatalogSection = TerminalCatalogSection()) {
        authoritativeKeys = [
            terminal.showTextBoxOnNewTerminals.userDefaultsKey,
            terminal.focusTextBoxOnNewTerminals.userDefaultsKey,
        ]
    }

    /// Returns present keys whose file values must replace app defaults.
    ///
    /// Removed keys are excluded so the importer can restore their backups.
    ///
    /// - Parameters:
    ///   - previous: The values previously imported from the file.
    ///   - next: The current file values.
    ///   - appliesFileAuthority: Whether unchanged authoritative keys also apply.
    /// - Returns: Changed keys, plus present authoritative keys when requested.
    public func keysToApply<Value: Equatable>(
        previous: [String: Value],
        next: [String: Value],
        appliesFileAuthority: Bool
    ) -> Set<String> {
        Set(next.compactMap { key, value in
            if appliesFileAuthority, authoritativeKeys.contains(key) {
                return key
            }
            return previous[key] == value ? nil : key
        })
    }
}
