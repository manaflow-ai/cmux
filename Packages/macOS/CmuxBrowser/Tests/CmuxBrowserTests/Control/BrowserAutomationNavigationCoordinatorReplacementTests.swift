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

    /// The user-agent policy can cancel and reissue a load at action-policy
    /// time, before WebKit reports a provisional start. The panel then has no
    /// provisional navigation to name, so the replacement arrives with a nil
    /// replaced identity (loopback `http://127.0.0.1` pages hit this through
    /// `browser.navigate`, which then timed out although the page loaded).
    @Test("A replacement made before the provisional start keeps the transaction")
    func preProvisionalReplacementTransfersTransaction() async {
        let coordinator = BrowserAutomationNavigationCoordinator(navigationTimeout: .milliseconds(500))
        let instanceID = UUID()
        let target = URL(string: "http://127.0.0.1:8123/index.html")!
        let originalNavigation = NSObject()
        let replacementNavigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: target, allowsSameDocumentCompletion: true)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(originalNavigation))

        coordinator.willReplaceNavigation(instanceID: instanceID, navigationID: nil, requestURL: target)
        coordinator.didReplaceNavigation(
            instanceID: instanceID,
            replacedNavigationID: nil,
            replacementNavigationID: ObjectIdentifier(replacementNavigation)
        )
        coordinator.didStart(instanceID: instanceID, navigationID: ObjectIdentifier(replacementNavigation), targetURL: target)
        coordinator.didCommit(instanceID: instanceID, navigationID: ObjectIdentifier(replacementNavigation))

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    /// The page's own navigation, restarted for the user agent before the
    /// automation's load reached its provisional start, is not the
    /// automation's navigation.
    @Test("A pre-provisional replacement of another URL is not adopted")
    func preProvisionalReplacementOfAnotherURLIsIgnored() async {
        let coordinator = BrowserAutomationNavigationCoordinator(navigationTimeout: .milliseconds(500))
        let instanceID = UUID()
        let target = URL(string: "http://127.0.0.1:8123/index.html")!
        let automationNavigation = NSObject()
        let pageNavigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: target)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(automationNavigation))

        coordinator.willReplaceNavigation(
            instanceID: instanceID,
            navigationID: nil,
            requestURL: URL(string: "https://example.com/elsewhere")!
        )
        coordinator.didReplaceNavigation(
            instanceID: instanceID,
            replacedNavigationID: nil,
            replacementNavigationID: ObjectIdentifier(pageNavigation)
        )
        coordinator.didCommit(instanceID: instanceID, navigationID: ObjectIdentifier(pageNavigation))
        coordinator.didStart(instanceID: instanceID, navigationID: ObjectIdentifier(automationNavigation), targetURL: target)
        coordinator.didCommit(instanceID: instanceID, navigationID: ObjectIdentifier(automationNavigation))

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    /// The previous page was still loading when the automation navigated, so
    /// the panel names that page's navigation as the one being replaced.
    @Test("A pre-provisional replacement that names the previous page's navigation keeps the transaction")
    func preProvisionalReplacementNamingAStaleNavigationTransfersTransaction() async {
        let coordinator = BrowserAutomationNavigationCoordinator(navigationTimeout: .milliseconds(500))
        let instanceID = UUID()
        let target = URL(string: "http://127.0.0.1:8123/index.html")!
        let previousPageNavigation = NSObject()
        let automationNavigation = NSObject()
        let replacementNavigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: target)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(automationNavigation))

        coordinator.willReplaceNavigation(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(previousPageNavigation),
            requestURL: target
        )
        coordinator.didReplaceNavigation(
            instanceID: instanceID,
            replacedNavigationID: ObjectIdentifier(previousPageNavigation),
            replacementNavigationID: ObjectIdentifier(replacementNavigation)
        )
        coordinator.didStart(instanceID: instanceID, navigationID: ObjectIdentifier(replacementNavigation), targetURL: target)
        coordinator.didCommit(instanceID: instanceID, navigationID: ObjectIdentifier(replacementNavigation))

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test("A nil replaced identity after the provisional start is not adopted")
    func nilReplacementAfterProvisionalStartIsIgnored() async {
        let coordinator = BrowserAutomationNavigationCoordinator(navigationTimeout: .milliseconds(500))
        let instanceID = UUID()
        let originalNavigation = NSObject()
        let unrelatedNavigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(originalNavigation))
        coordinator.didStart(instanceID: instanceID, navigationID: ObjectIdentifier(originalNavigation))

        // Once the original has started provisionally, a replacement must name it.
        coordinator.willReplaceNavigation(instanceID: instanceID, navigationID: nil)
        coordinator.didReplaceNavigation(
            instanceID: instanceID,
            replacedNavigationID: nil,
            replacementNavigationID: ObjectIdentifier(unrelatedNavigation)
        )
        coordinator.didCommit(instanceID: instanceID, navigationID: ObjectIdentifier(originalNavigation))

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
