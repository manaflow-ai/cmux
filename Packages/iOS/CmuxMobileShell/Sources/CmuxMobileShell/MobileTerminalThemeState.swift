import CMUXMobileCore

struct MobileTerminalThemeState {
    var hostTheme: TerminalTheme = .monokai
    var themesBySurfaceID: [String: TerminalTheme] = [:]
    var activeTheme: TerminalTheme = .monokai
    var generation: UInt64 = 0

    func theme(for surfaceID: String) -> TerminalTheme {
        themesBySurfaceID[surfaceID] ?? hostTheme
    }
}
