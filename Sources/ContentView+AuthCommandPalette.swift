import CmuxCommandPalette
import AppKit
import Foundation

extension ContentView {
    static let commandPaletteAuthSignInCommandId = CommandPaletteAuthContributionProvider.signInCommandId
    static let commandPaletteAuthSignOutCommandId = CommandPaletteAuthContributionProvider.signOutCommandId

    static func commandPaletteAuthCommandContributions() -> [CommandPaletteCommandContribution] {
        CommandPaletteAuthContributionProvider().build(
            strings: CommandPaletteAuthContributionProvider.Strings(
                signInTitle: String(localized: "command.auth.signIn.title", defaultValue: "Sign In"),
                signOutTitle: String(localized: "command.auth.signOut.title", defaultValue: "Sign Out"),
                subtitle: String(localized: "command.auth.subtitle", defaultValue: "Account")
            )
        )
    }

    func registerAuthCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.commandPaletteAuthSignInCommandId) {
#if DEBUG
            cmuxDebugLog("palette.auth.signIn.invoke")
#endif
            guard let auth = appEnvironment?.auth else {
                NSSound.beep()
                return
            }
            auth.browserSignIn.beginSignIn()
        }
        registry.register(commandId: Self.commandPaletteAuthSignOutCommandId) {
#if DEBUG
            cmuxDebugLog("palette.auth.signOut.invoke")
#endif
            guard let auth = appEnvironment?.auth else {
                NSSound.beep()
                return
            }
            Task { @MainActor in
                await auth.browserSignIn.signOut()
            }
        }
    }
}
