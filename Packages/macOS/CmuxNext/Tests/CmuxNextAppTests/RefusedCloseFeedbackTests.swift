import AppKit
@testable import CmuxNextApp
import Testing

/// nxdog64-v1: Cmd-W on a permanent docked column was refused by the daemon
/// with no feedback at all. A user's close the daemon refuses now shows a
/// notice (with a beep): a permanent column says it stays docked.
@MainActor @Suite(.serialized) struct RefusedCloseFeedbackTests {
    @Test func aPermanentColumnSaysItStaysDocked() async throws {
        let (services, window, _, _) = try await TopPageTests.window()
        RefusedCloseNotice(services: services).show(codes: [RefusedCloseNotice.permanentColumnCode], in: window.window)
        #expect(services.refusalHUD.message == RefusalStrings.columnStaysDocked)
        window.teardown()
        withExtendedLifetime(services) {}
    }

    @Test func anyOtherRefusalSaysTheTabStayed() async throws {
        let (services, window, _, _) = try await TopPageTests.window()
        let before = services.refusalHUD.shownCount
        RefusedCloseNotice(services: services).show(codes: [], in: window.window)
        #expect(services.refusalHUD.shownCount == before + 1)
        #expect(services.refusalHUD.message == RefusalStrings.closeRefused)
        window.teardown()
        withExtendedLifetime(services) {}
    }
}
