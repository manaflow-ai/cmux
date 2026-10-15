import Foundation
import Testing

@testable import CmuxBrowser

/// Automation navigations on a non-WebKit engine page, which have no
/// `WKNavigation` identity.
@MainActor
@Suite("Browser automation engine navigations")
struct BrowserAutomationEngineNavigationTests {
    @Test("An engine navigation completes on the engine's commit, not as not-started")
    func engineCommitCompletes() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)

        coordinator.didStartEngineNavigation(ticket)
        coordinator.didCommitEngineNavigation(instanceID: instanceID)

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test("An engine navigation failure is reported as failed")
    func engineFailureFails() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)

        coordinator.didStartEngineNavigation(ticket)
        coordinator.didFailEngineNavigation(instanceID: instanceID, message: "net::ERR_NAME_NOT_RESOLVED")

        #expect(await coordinator.wait(for: ticket) == .failed("net::ERR_NAME_NOT_RESOLVED"))
    }

    @Test("Another panel's engine commit does not finish the navigation")
    func otherInstanceIgnored() {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)
        coordinator.didStartEngineNavigation(ticket)

        coordinator.didCommitEngineNavigation(instanceID: UUID())

        #expect(ticket.transaction.takeTerminalOutcome() == nil)
    }
}
