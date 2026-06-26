import CmuxSettings
import Foundation

/// App-side conformer wiring ``ManagedDefaultsBackupService``'s palette seam to
/// ``WorkspaceTabColorSettings``, which lives in the app target and cannot be
/// referenced from `CmuxSettings`. Each method is a thin forward so the managed
/// defaults backup/restore engine treats the palette key exactly as before.
struct WorkspaceTabColorPaletteSeam: ManagedDefaultsPaletteSeam {
    var paletteKey: String { WorkspaceTabColorSettings.paletteKey }

    func backupPaletteMap(defaults: UserDefaults) -> [String: String]? {
        WorkspaceTabColorSettings.backupPaletteMap(defaults: defaults)
    }

    func reset(defaults: UserDefaults) {
        WorkspaceTabColorSettings.reset(defaults: defaults)
    }

    func persistPaletteMap(_ map: [String: String], defaults: UserDefaults) {
        WorkspaceTabColorSettings.persistPaletteMap(map, defaults: defaults)
    }

    func resolvedPaletteMap(defaults: UserDefaults) -> [String: String] {
        WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults)
    }
}
