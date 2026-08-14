import CmuxCommandPalette
import AppKit
import Foundation

extension CommandPaletteContextKeys {
    static let proUpgradeEnabled = CommandPaletteContextKeys(rawValue: "pro.upgradeEnabled")
}

extension ContentView {
    static let commandPaletteProUpgradeCommandId = "palette.pro.upgrade"
    static let commandPaletteProWelcomeChecklistCommandId = "palette.pro.welcomeChecklist"

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

    func registerProCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.commandPaletteProUpgradeCommandId) {
#if DEBUG
            cmuxDebugLog("palette.pro.upgrade.invoke")
#endif
            ProUpgradePresenter.present()
        }
        registry.register(commandId: Self.commandPaletteProWelcomeChecklistCommandId) {
#if DEBUG
            cmuxDebugLog("palette.pro.welcomeChecklist.invoke")
#endif
            ProWelcomeChecklistPresenter.present()
        }
    }
}
