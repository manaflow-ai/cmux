import CmuxCommandPalette
import AppKit
import Foundation

extension CommandPaletteContextKeys {
    static let proUpgradeEnabled = CommandPaletteContextKeys(rawValue: "pro.upgradeEnabled")
}

extension ContentView {
    static let commandPaletteProUpgradeCommandId = "palette.pro.upgrade"
    static let commandPaletteProWelcomeChecklistCommandId = "palette.pro.welcomeChecklist"

    static func commandPaletteProPresentationResult(
        targetAvailable: Bool
    ) -> CmuxActionExecutionResult {
        targetAvailable ? .presented : .targetUnavailable
    }

    static func commandPaletteProCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: commandPaletteProWelcomeChecklistCommandId,
                title: constant(String(localized: "command.pro.welcomeChecklist.title", defaultValue: "Welcome to cmux Pro")),
                subtitle: constant(String(localized: "command.auth.subtitle", defaultValue: "Account")),
                keywords: ["pro", "welcome", "checklist", "onboarding", "cloud", "billing", "ios", "provider"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.proUpgradeEnabled)
                }
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteProUpgradeCommandId,
                title: constant(String(localized: "command.pro.upgrade.title", defaultValue: "Upgrade to cmux Pro")),
                subtitle: constant(String(localized: "command.auth.subtitle", defaultValue: "Account")),
                keywords: ["pro", "upgrade", "subscription", "billing", "plan", "pricing", "cloud", "purchase", "buy"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.proUpgradeEnabled)
                }
            ),
        ]
    }

    func registerProCommandHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        context: CommandPaletteActionContext
    ) {
        registry.register(commandId: Self.commandPaletteProUpgradeCommandId) { _ in
#if DEBUG
            cmuxDebugLog("palette.pro.upgrade.invoke")
#endif
            guard context.target.windowID == windowId,
                  context.owningWindowID == windowId,
                  ProUpgradePresenter.capturedSourceIsAvailable(
                appDelegate: AppDelegate.shared,
                tabManager: context.tabManager,
                sourceWindowID: context.target.windowID,
                sourceWorkspaceID: context.target.workspaceID,
                sourcePanelID: context.target.panelID
            ) else {
                return Self.commandPaletteProPresentationResult(targetAvailable: false)
            }
            ProUpgradePresenter.present(
                tabManager: context.tabManager,
                sourceWindowID: context.target.windowID,
                sourceWorkspaceID: context.target.workspaceID,
                sourcePanelID: context.target.panelID
            )
            return Self.commandPaletteProPresentationResult(targetAvailable: true)
        }
        registry.register(commandId: Self.commandPaletteProWelcomeChecklistCommandId) { _ in
#if DEBUG
            cmuxDebugLog("palette.pro.welcomeChecklist.invoke")
#endif
            guard context.target.windowID == windowId,
                  context.owningWindowID == windowId,
                  ProUpgradePresenter.capturedSourceIsAvailable(
                appDelegate: AppDelegate.shared,
                tabManager: context.tabManager,
                sourceWindowID: context.target.windowID,
                sourceWorkspaceID: context.target.workspaceID,
                sourcePanelID: context.target.panelID
            ) else {
                return Self.commandPaletteProPresentationResult(targetAvailable: false)
            }
            ProWelcomeChecklistPresenter.present(
                tabManager: context.tabManager,
                sourceWindowID: context.target.windowID,
                sourceWorkspaceID: context.target.workspaceID,
                sourcePanelID: context.target.panelID
            )
            return Self.commandPaletteProPresentationResult(targetAvailable: true)
        }
    }
}
