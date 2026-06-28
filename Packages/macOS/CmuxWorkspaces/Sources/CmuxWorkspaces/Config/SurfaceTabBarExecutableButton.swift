/// An entry in a surface tab bar's executable-button map: the resolved
/// ``CmuxSurfaceTabBarButton`` plus the classification needed to run it, a
/// non-bonsplit built-in action, a resolved workspace command, or a terminal
/// command with its config source path. A pure value model the workspace builds
/// once per config apply and looks up when a tab-bar button is activated.
public struct SurfaceTabBarExecutableButton: Sendable {
    public let button: CmuxSurfaceTabBarButton
    public let builtInAction: CmuxSurfaceTabBarBuiltInAction?
    public let workspaceCommand: CmuxResolvedCommand?
    public let terminalCommandSourcePath: String?

    public init(
        button: CmuxSurfaceTabBarButton,
        builtInAction: CmuxSurfaceTabBarBuiltInAction?,
        workspaceCommand: CmuxResolvedCommand?,
        terminalCommandSourcePath: String?
    ) {
        self.button = button
        self.builtInAction = builtInAction
        self.workspaceCommand = workspaceCommand
        self.terminalCommandSourcePath = terminalCommandSourcePath
    }

    /// Builds the id-keyed executable-button map for a surface tab bar, classifying
    /// each button as a terminal command (carrying its source path), a resolved
    /// workspace command, or a non-bonsplit built-in action, and dropping buttons
    /// whose built-in action bonsplit handles directly. Byte-identical to the
    /// former inline construction in `Workspace.applySurfaceTabBarButtons`.
    public static func executableButtons(
        for buttons: [CmuxSurfaceTabBarButton],
        terminalCommandSourcePaths: [String: String],
        workspaceCommands: [String: CmuxResolvedCommand]
    ) -> [String: SurfaceTabBarExecutableButton] {
        Dictionary(
            uniqueKeysWithValues: buttons.compactMap { button in
                if button.terminalCommand != nil {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: nil,
                            workspaceCommand: nil,
                            terminalCommandSourcePath: button.actionSourcePath ?? terminalCommandSourcePaths[button.id]
                        )
                    )
                }
                if let workspaceCommand = workspaceCommands[button.id] {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: nil,
                            workspaceCommand: workspaceCommand,
                            terminalCommandSourcePath: nil
                        )
                    )
                }
                if case .builtIn(let builtInAction) = button.action,
                   builtInAction.bonsplitAction == nil {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: builtInAction,
                            workspaceCommand: nil,
                            terminalCommandSourcePath: nil
                        )
                    )
                }
                return nil
            }
        )
    }
}
