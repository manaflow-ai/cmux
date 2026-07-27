struct SurfaceTabBarButtonConfiguration {
    let buttons: [CmuxSurfaceTabBarButton]
    let sourcePath: String?
    let globalConfigPath: String
    let terminalCommandSourcePaths: [String: String]
    let workspaceCommands: [String: CmuxResolvedCommand]
}
