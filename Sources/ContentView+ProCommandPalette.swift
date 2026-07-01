import CmuxCommandPalette
import AppKit
import Foundation

extension ContentView {
    static let commandPaletteProUpgradeCommandId = "palette.pro.upgrade"

    static func commandPaletteProCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: commandPaletteProUpgradeCommandId,
                title: constant(String(localized: "command.pro.upgrade.title", defaultValue: "Upgrade to cmux Pro")),
                subtitle: constant(String(localized: "command.auth.subtitle", defaultValue: "Account")),
                keywords: ["pro", "upgrade", "subscription", "billing", "plan", "pricing", "cloud", "purchase", "buy"]
            ),
        ]
    }

    func registerProCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.commandPaletteProUpgradeCommandId) {
#if DEBUG
            cmuxDebugLog("palette.pro.upgrade.invoke")
#endif
            NSWorkspace.shared.open(AuthEnvironment.pricingURL)
        }
    }
}
