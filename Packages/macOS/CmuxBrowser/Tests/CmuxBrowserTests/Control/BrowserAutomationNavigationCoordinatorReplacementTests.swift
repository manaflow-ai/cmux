import Foundation
import Testing

@testable import CmuxBrowser

@MainActor
@Suite("Browser automation navigation replacement")
struct BrowserAutomationNavigationCoordinatorReplacementTests {
    @Test("An authoritative policy replacement preserves the active transaction")
    func policyReplacementTransfersTransaction() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let originalNavigation = NSObject()
        let replacementNavigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(originalNavigation))

        coordinator.willReplaceNavigation(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(originalNavigation)
        )
        coordinator.didReplaceNavigation(
            instanceID: instanceID,
            replacedNavigationID: ObjectIdentifier(originalNavigation),
            replacementNavigationID: ObjectIdentifier(replacementNavigation)
        )
        coordinator.didCancel(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(originalNavigation)
        )
        coordinator.didCommit(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(replacementNavigation)
        )

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test("An identity-changing redirect stays pending across an insecure HTTP prompt")
    func identityChangingRedirectSurvivesDeferredInsecureHTTPPrompt() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let originalNavigation = NSObject()
        let replacementNavigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(originalNavigation))

        coordinator.willReplaceNavigation(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(originalNavigation)
        )
        // The replacement load is deferred while BrowserPanel presents the prompt. WebKit
        // reports both forms of cancellation for the redirect before the user responds.
        #expect(!coordinator.didInterruptByPolicyChange(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(originalNavigation)
        ))
        coordinator.didCancel(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(originalNavigation)
        )
        coordinator.didReplaceNavigation(
            instanceID: instanceID,
            replacedNavigationID: ObjectIdentifier(originalNavigation),
            replacementNavigationID: ObjectIdentifier(replacementNavigation)
        )
        coordinator.didCommit(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(replacementNavigation)
        )

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test("Declining a deferred policy replacement cancels the transaction")
    func declinedPolicyReplacementCancelsTransaction() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let originalNavigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(originalNavigation))

        coordinator.willReplaceNavigation(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(originalNavigation)
        )
        coordinator.didCancel(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(originalNavigation)
        )
        coordinator.didReplaceNavigation(
            instanceID: instanceID,
            replacedNavigationID: ObjectIdentifier(originalNavigation),
            replacementNavigationID: nil
        )

        #expect(await coordinator.wait(for: ticket) == .cancelled)
    }
}
