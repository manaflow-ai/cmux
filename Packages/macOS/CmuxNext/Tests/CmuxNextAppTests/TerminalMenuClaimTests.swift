import AppKit
@testable import CmuxNextApp
import Testing

/// nxdog50 Cmd-T: the dispatcher delivered the key to the terminal (a user
/// Ghostty keybind beats the cmux default), every menu gate refused, and yet
/// the main menu "took" it (a matching item that is refused still claims its
/// key equivalent), so Ghostty never ran the binding. A key the dispatcher
/// decided must not be offered to the menu by the terminal.
@MainActor
struct TerminalMenuClaimTests {
    @Test func aKeyTheDispatcherDecidedIsNotOfferedToTheMenu() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let router = try #require(services.keyRouter)
        let event = try KeyInterceptionTests.key("t", keyCode: 17, [.command])
        router.decided.add(event)
        #expect(!router.menuMayClaim(event))
    }

    /// A key the dispatcher never saw (a synthetic event) keeps the menu-first rule.
    @Test func anUndecidedKeyMayStillGoToTheMenu() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let router = try #require(services.keyRouter)
        #expect(router.menuMayClaim(try KeyInterceptionTests.key("t", keyCode: 17, [.command])))
    }
}
