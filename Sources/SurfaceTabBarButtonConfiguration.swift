import CmuxSettings

struct SurfaceTabBarButtonConfiguration {
    let buttons: [CmuxSurfaceTabBarButton]
    let sourcePath: String?
    let globalConfigPath: String
    let settingPresets: [String: CmuxSettingValue]
    let terminalCommandSourcePaths: [String: String]
    let workspaceCommands: [String: CmuxResolvedCommand]
}
