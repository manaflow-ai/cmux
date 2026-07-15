import Foundation

struct CmuxSurfaceTabBarMenuItem: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String?
    var icon: CmuxButtonIcon?
    var tooltip: String?
    var action: CmuxSurfaceTabBarButtonAction
    var confirm: Bool?
    var terminalCommandTarget: CmuxConfigTerminalCommandTarget?
    var actionSourcePath: String?
    var iconSourcePath: String?

    var command: String? {
        action.terminalCommand
    }

    var terminalCommand: String? {
        action.terminalCommand
    }

    var resolvedTerminalCommandTarget: CmuxConfigTerminalCommandTarget {
        terminalCommandTarget ?? CmuxConfigTerminalCommandTarget.defaultForActions
    }

    var workspaceCommandName: String? {
        action.workspaceCommandName
    }

    var button: CmuxSurfaceTabBarButton {
        CmuxSurfaceTabBarButton(
            id: id,
            title: title,
            icon: icon,
            tooltip: tooltip,
            action: action,
            menu: nil,
            confirm: confirm,
            terminalCommandTarget: terminalCommandTarget,
            actionSourcePath: actionSourcePath,
            iconSourcePath: iconSourcePath
        )
    }

    init(_ button: CmuxSurfaceTabBarButton) {
        id = button.id
        title = button.title
        icon = button.icon
        tooltip = button.tooltip
        action = button.action
        confirm = button.confirm
        terminalCommandTarget = button.terminalCommandTarget
        actionSourcePath = button.actionSourcePath
        iconSourcePath = button.iconSourcePath
    }

    static func actionReference(
        _ actionID: String,
        title: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil
    ) -> CmuxSurfaceTabBarMenuItem {
        CmuxSurfaceTabBarMenuItem(
            CmuxSurfaceTabBarButton.actionReference(
                actionID,
                title: title,
                icon: icon,
                tooltip: tooltip
            )
        )
    }

    init(from decoder: Decoder) throws {
        let decodedButton = try CmuxSurfaceTabBarButton(from: decoder)
        if decodedButton.menu != nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "surface tab bar menu items cannot define nested menus"
                )
            )
        }
        self.init(decodedButton)
    }

    func encode(to encoder: Encoder) throws {
        try button.encode(to: encoder)
    }
}
