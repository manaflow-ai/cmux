import CmuxSettings

struct SurfaceTabBarButtonConfiguration {
    let buttons: [CmuxSurfaceTabBarButton]
    let sourcePath: String?
    let globalConfigPath: String
    let settingPresets: [String: CmuxSettingValue]
    let terminalCommandSourcePaths: [String: String]
    let workspaceCommands: [String: CmuxResolvedCommand]
    /// True when no `cmux.json` sets the buttons and the compact cluster shows instead.
    let usesCompactCluster: Bool
}
