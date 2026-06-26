import Foundation

/// App-provided seam for the workspace tab-color palette, whose `UserDefaults`
/// persistence the managed-defaults backup/restore engine must treat specially.
///
/// The palette lives under one `UserDefaults` key but its value is not a plain
/// dictionary round-trip: capturing and restoring it goes through the app-side
/// `WorkspaceTabColorSettings` (legacy-map migration, name/hex normalization,
/// default-equality pruning). `CmuxSettings` cannot reference that app-target
/// type, so the app injects a conformer and ``ManagedDefaultsBackupService``
/// special-cases ``paletteKey``.
public protocol ManagedDefaultsPaletteSeam: Sendable {
    /// The `UserDefaults` key under which the palette map is persisted.
    var paletteKey: String { get }

    /// The palette map to back up before a managed default overrides it, or
    /// `nil` when no palette value is stored.
    func backupPaletteMap(defaults: UserDefaults) -> [String: String]?

    /// Restores the palette to its built-in default by clearing the stored value.
    func reset(defaults: UserDefaults)

    /// Persists `map` as the palette's stored value.
    func persistPaletteMap(_ map: [String: String], defaults: UserDefaults)
}
