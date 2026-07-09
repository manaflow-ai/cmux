import Foundation

extension Workspace {
    func makeSurfaceTabBarExecutableButton(
        _ button: CmuxSurfaceTabBarButton,
        terminalCommandSourcePaths: [String: String],
        workspaceCommands: [String: CmuxResolvedCommand],
        includeBonsplitHandledBuiltIns: Bool
    ) -> SurfaceTabBarExecutableButton? {
        let menuItems = (button.menu ?? []).compactMap {
            makeSurfaceTabBarExecutableButton(
                $0.button,
                terminalCommandSourcePaths: terminalCommandSourcePaths,
                workspaceCommands: workspaceCommands,
                includeBonsplitHandledBuiltIns: true
            )
        }
        let terminalCommandSourcePath = button.actionSourcePath ?? terminalCommandSourcePaths[button.id]
        if button.terminalCommand != nil {
            return SurfaceTabBarExecutableButton(
                button: button,
                builtInAction: nil,
                workspaceCommand: nil,
                terminalCommandSourcePath: terminalCommandSourcePath,
                menuItems: menuItems
            )
        }
        if let workspaceCommand = workspaceCommands[button.id] {
            return SurfaceTabBarExecutableButton(
                button: button,
                builtInAction: nil,
                workspaceCommand: workspaceCommand,
                terminalCommandSourcePath: nil,
                menuItems: menuItems
            )
        }
        if button.action.inlineWorkspace != nil {
            return SurfaceTabBarExecutableButton(
                button: button,
                builtInAction: nil,
                workspaceCommand: nil,
                terminalCommandSourcePath: nil,
                menuItems: menuItems
            )
        }
        if case .builtIn(let builtInAction) = button.action,
           includeBonsplitHandledBuiltIns || builtInAction.bonsplitAction == nil || !menuItems.isEmpty {
            return SurfaceTabBarExecutableButton(
                button: button,
                builtInAction: builtInAction,
                workspaceCommand: nil,
                terminalCommandSourcePath: nil,
                menuItems: menuItems
            )
        }
        if !menuItems.isEmpty {
            return SurfaceTabBarExecutableButton(
                button: button,
                builtInAction: nil,
                workspaceCommand: nil,
                terminalCommandSourcePath: nil,
                menuItems: menuItems
            )
        }
        return nil
    }
}
