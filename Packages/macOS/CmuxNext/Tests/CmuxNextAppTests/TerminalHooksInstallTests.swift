import AppKit
@testable import CmuxNextApp
import CmuxNextTerminal
import Testing

/// The launch path wires the terminal module's hooks (nxdog50: a key the
/// dispatcher decided must never go to the menu from a terminal; app-scoped
/// Ghostty actions must run). The hooks are process-wide: the test restores them.
@MainActor @Suite(.serialized) struct TerminalHooksInstallTests {
    @Test func installingTheHooksRoutesDecidedKeysAwayFromTheMenu() throws {
        let previousClaim = TerminalKeyEquivalent.menuMayClaim
        let previousApp = GhosttyRuntime.shared.appActionHandler
        defer {
            TerminalKeyEquivalent.menuMayClaim = previousClaim
            GhosttyRuntime.shared.appActionHandler = previousApp
        }
        TerminalKeyEquivalent.menuMayClaim = nil
        GhosttyRuntime.shared.appActionHandler = nil
        let services = ActionBindingCoverageTests.boundServices()
        TerminalHooks(services: services).install()
        let event = try KeyInterceptionTests.key("t", keyCode: 17, [.command])
        services.keyRouter.decided.add(event)
        #expect(TerminalKeyEquivalent.menuMayClaim?(event) == false)
        #expect(GhosttyRuntime.shared.appActionHandler != nil)
    }
}
