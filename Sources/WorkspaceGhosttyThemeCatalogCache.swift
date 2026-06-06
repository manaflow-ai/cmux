import Foundation

@MainActor
enum WorkspaceGhosttyThemeCatalogCache {
    private static var cachedThemeNames: [String]?

    static func availableThemeNames() -> [String] {
        if let cachedThemeNames {
            return cachedThemeNames
        }

        let resolved = WorkspaceGhosttyThemeCatalog.availableThemeNames()
        cachedThemeNames = resolved
        return resolved
    }

    static func invalidate() {
        cachedThemeNames = nil
    }
}
