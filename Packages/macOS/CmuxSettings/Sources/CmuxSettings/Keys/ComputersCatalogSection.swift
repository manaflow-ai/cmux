import Foundation

/// Settings for paired remote computers (the `computers.*` keys). The pairing
/// itself lives in the device registry and the local paired store; this
/// section holds how paired computers are presented.
public struct ComputersCatalogSection: SettingCatalogSection {
    /// How remote computers are shown: `windows` (default; one auxiliary
    /// viewer window per computer) or `sidebar` (merged into the main window
    /// behind the sidebar's computer scope picker).
    ///
    /// JSON-backed so it can be flipped by editing `~/.config/cmux/cmux.json`:
    ///
    /// ```json
    /// { "computers": { "presentation": "sidebar" } }
    /// ```
    public let presentation = JSONKey<ComputersPresentationMode>(
        id: "computers.presentation",
        defaultValue: .windows
    )

    public init() {}
}
