import CMUXMobileCore

struct MobileTerminalThemeState {
    var hostTheme: TerminalTheme = .monokai
    var themesBySurfaceID: [String: TerminalTheme] = [:]
    var configThemesBySurfaceID: [String: TerminalTheme] = [:]
    var revisionsBySurfaceID: [String: UInt64] = [:]
    var revisionAuthority: String?

    func theme(for surfaceID: String) -> TerminalTheme {
        themesBySurfaceID[surfaceID] ?? hostTheme
    }

    func configTheme(for surfaceID: String) -> TerminalTheme {
        configThemesBySurfaceID[surfaceID] ?? hostTheme
    }
}
