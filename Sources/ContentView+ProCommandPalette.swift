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
        targetAvailable: Bool,
        didPresent: Bool
    ) -> CmuxActionExecutionResult {
        guard targetAvailable else { return .targetUnavailable }
        guard didPresent else {
            return .failed(
                code: "presentation_failed",
                message: String(
                    localized: "action.error.configuredActionFailed",
                    defaultValue: "The configured action could not be started."
                )
            )
        }
        return .presented
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
        context: CommandPaletteActionContext,
        presentUpgrade: (@MainActor (TabManager, CommandPaletteActionTarget) -> Bool)? = nil,
        presentWelcomeChecklist: (@MainActor (TabManager, CommandPaletteActionTarget) -> Bool)? = nil
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
                return Self.commandPaletteProPresentationResult(
                    targetAvailable: false,
                    didPresent: false
                )
            }
            let didPresent = if let presentUpgrade {
                presentUpgrade(context.tabManager, context.target)
            } else {
                ProUpgradePresenter.present(
                    tabManager: context.tabManager,
                    sourceWindowID: context.target.windowID,
                    sourceWorkspaceID: context.target.workspaceID,
                    sourcePanelID: context.target.panelID
                )
            }
            return Self.commandPaletteProPresentationResult(
                targetAvailable: true,
                didPresent: didPresent
            )
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
                return Self.commandPaletteProPresentationResult(
                    targetAvailable: false,
                    didPresent: false
                )
            }
            let didPresent = if let presentWelcomeChecklist {
                presentWelcomeChecklist(context.tabManager, context.target)
            } else {
                ProWelcomeChecklistPresenter.present(
                    tabManager: context.tabManager,
                    sourceWindowID: context.target.windowID,
                    sourceWorkspaceID: context.target.workspaceID,
                    sourcePanelID: context.target.panelID
                )
            }
            return Self.commandPaletteProPresentationResult(
                targetAvailable: true,
                didPresent: didPresent
            )
        }
    }
}
