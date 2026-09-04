import Foundation

extension WorkspaceTabColorSettings {
    static func resolvedColorHex(_ raw: String, defaults: UserDefaults = .standard) -> String? {
        CmuxConfigWorkspaceColorPalette.resolvedColorHex(raw, defaults: defaults)
    }

    static func paletteCacheFingerprint(defaults: UserDefaults = .standard) -> String {
        resolvedPaletteMap(defaults: defaults)
            .sorted { lhs, rhs in lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }
}
