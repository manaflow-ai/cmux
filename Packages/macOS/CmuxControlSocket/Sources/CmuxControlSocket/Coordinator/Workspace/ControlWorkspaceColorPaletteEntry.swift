/// One named color in the workspace tab-color palette snapshot, passed into
/// ``ControlWorkspaceActionResolution/resolve(action:title:description:color:palette:)``
/// for the `set_color` action.
///
/// The app reads its effective palette (`WorkspaceTabColorSettings.palette()`)
/// and maps each entry into this value so the resolution can match a requested
/// color name against the palette and echo the available names on failure,
/// without the package depending on the app-side color settings.
public struct ControlWorkspaceColorPaletteEntry: Sendable, Equatable {
    /// The display name of the palette color (e.g. `"Blue"`).
    public let name: String
    /// The normalized hex string for the color (e.g. `"#1565C0"`).
    public let hex: String

    /// Creates a palette entry.
    ///
    /// - Parameters:
    ///   - name: The display name of the palette color.
    ///   - hex: The normalized hex string for the color.
    public init(name: String, hex: String) {
        self.name = name
        self.hex = hex
    }
}
