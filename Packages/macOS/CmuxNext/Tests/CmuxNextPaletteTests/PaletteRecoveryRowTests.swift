import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// HQ #4884: a row disabled by a reason a recovery answers (Sign In for a signed-out Cloud
/// action) is enabled, says what running it does, and runs the recovery.
@MainActor
struct PaletteRecoveryRowTests {
    @Test func aRecoverableRowIsEnabledWithTheRecoveryNote() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var signedIn = false, recovered = 0
        registry.bind("cloudOpenDesktop", unavailable: { signedIn ? nil : "sign in" }, invoke: { _ in })
        registry.unavailableRecoveries.append { _, reason in
            reason == "sign in" ? ActionRecovery(note: "Choose it to sign in, then it runs.") { _, _ in recovered += 1 } : nil
        }
        func row() throws -> PaletteItem {
            try #require(RegistryPaletteProvider(registry: registry).makeItems().first { $0.actionID == "cloudOpenDesktop" })
        }
        let signedOut = try row()
        #expect(signedOut.isEnabled)
        #expect(signedOut.subtitle == "Choose it to sign in, then it runs.")
        #expect(registry.perform("cloudOpenDesktop", invocation: ActionInvocation()))
        #expect(recovered == 1)
        signedIn = true
        let ready = try row()
        #expect(ready.isEnabled)
        #expect(ready.subtitle == nil)
    }
}
