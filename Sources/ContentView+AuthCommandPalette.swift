import CmuxCommandPalette
import AppKit
import Foundation

extension ContentView {
    static let commandPaletteAuthSignInCommandId = "palette.auth.signIn"
    static let commandPaletteAuthSignOutCommandId = "palette.auth.signOut"

    static func commandPaletteAuthCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: commandPaletteAuthSignInCommandId,
                title: constant(String(localized: "command.auth.signIn.title", defaultValue: "Sign In")),
                subtitle: constant(String(localized: "command.auth.subtitle", defaultValue: "Account")),
                keywords: ["account", "auth", "authenticate", "authentication", "login", "log in", "signin", "sign in"],
                when: { context in
                    !context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteAuthSignOutCommandId,
                title: constant(String(localized: "command.auth.signOut.title", defaultValue: "Sign Out")),
                subtitle: constant(String(localized: "command.auth.subtitle", defaultValue: "Account")),
                keywords: ["account", "auth", "logout", "log out", "signout", "sign out"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
        ]
    }

    func registerAuthCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.commandPaletteAuthSignInCommandId) {
#if DEBUG
            cmuxDebugLog("palette.auth.signIn.invoke")
#endif
            guard let auth = AppDelegate.shared?.auth else {
                NSSound.beep()
                return
            }
            auth.browserSignIn.beginSignIn()
        }
        registry.register(commandId: Self.commandPaletteAuthSignOutCommandId) {
#if DEBUG
            cmuxDebugLog("palette.auth.signOut.invoke")
#endif
            guard let auth = AppDelegate.shared?.auth else {
                NSSound.beep()
                return
            }
            Task { @MainActor in
                await auth.browserSignIn.signOut()
            }
        }
    }
}
