import Foundation
import Testing

@testable import CmuxBrowser

@MainActor
@Suite("Browser automation navigation coordinator")
struct BrowserAutomationNavigationCoordinatorTests {
    @Test("The exact started navigation commit completes the transaction")
    func exactNavigationCommitCompletesTransaction() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let navigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))

        coordinator.didCommit(instanceID: instanceID, navigationID: ObjectIdentifier(navigation))

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test("A delegate commit releases an already waiting transaction")
    func commitReleasesWaitingTransaction() async {
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let navigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))
        let wait = Task { @MainActor in
            registrationContinuation.yield()
            return await coordinator.wait(for: ticket)
        }
        let registered: Void? = await registrationIterator.next()
        #expect(registered != nil)

        coordinator.didCommit(instanceID: instanceID, navigationID: ObjectIdentifier(navigation))

        #expect(await wait.value == .committed)
        registrationContinuation.finish()
    }

    @Test("Cancelling a wait cancels its active transaction")
    func cancellingWaitCancelsTransaction() async {
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let navigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))
        let wait = Task { @MainActor in
            registrationContinuation.yield()
            return await coordinator.wait(for: ticket)
        }
        let registered: Void? = await registrationIterator.next()
        #expect(registered != nil)

        wait.cancel()

        #expect(await wait.value == .cancelled)
        registrationContinuation.finish()
    }

    @Test("A different navigation cannot satisfy the active transaction")
    func unrelatedCommitIsIgnored() async {
        let coordinator = BrowserAutomationNavigationCoordinator(
            sleep: { _ in }
        )
        let instanceID = UUID()
        let requestedNavigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(requestedNavigation))

        coordinator.didCommit(instanceID: instanceID, navigationID: ObjectIdentifier(NSObject()))

        #expect(await coordinator.wait(for: ticket) == .timedOut)
    }

    @Test("A failure delivered before waiting remains observable")
    func earlyFailureRemainsObservable() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let navigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))
        coordinator.didFail(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(navigation),
            message: "connection refused"
        )

        #expect(await coordinator.wait(for: ticket) == .failed("connection refused"))
    }

    @Test("A completed outcome survives a newer transaction beginning")
    func completedOutcomeSurvivesNewerTransaction() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let firstNavigation = NSObject()
        coordinator.bind(to: instanceID)
        let firstTicket = coordinator.begin(instanceID: instanceID)
        coordinator.didStart(firstTicket, navigationID: ObjectIdentifier(firstNavigation))
        coordinator.didCommit(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(firstNavigation)
        )

        _ = coordinator.begin(instanceID: instanceID)

        #expect(await coordinator.wait(for: firstTicket) == .committed)
    }

    @Test("An abandoned terminal outcome is released with its ticket")
    func abandonedTerminalOutcomeIsReleased() {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        coordinator.bind(to: instanceID)
        weak var transaction: BrowserAutomationNavigationTransaction?

        do {
            let navigation = NSObject()
            let ticket = coordinator.begin(instanceID: instanceID)
            transaction = ticket.transaction
            coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))
            coordinator.didFail(
                instanceID: instanceID,
                navigationID: ObjectIdentifier(navigation),
                message: "connection refused"
            )
        }

        #expect(transaction == nil)
    }

    @Test("A deferred load can bind when its real navigation starts")
    func deferredLoadBindsOnStart() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let navigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)

        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))
        coordinator.didCommit(instanceID: instanceID, navigationID: ObjectIdentifier(navigation))

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test("An unrelated deferred navigation supersedes the transaction")
    func unrelatedDeferredNavigationSupersedes() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let expectedURL = URL(string: "https://example.com/expected")!
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: expectedURL)

        coordinator.didStart(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(NSObject()),
            targetURL: URL(string: "https://example.com/unrelated")!
        )

        #expect(await coordinator.wait(for: ticket) == .superseded)
    }

    @Test("An uncorrelated policy replacement cannot seize the active transaction")
    func policyReplacementCannotSeizeTransaction() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let originalNavigation = NSObject()
        let replacementNavigation = NSObject()
        let originalURL = URL(string: "https://example.com/launch")!
        let fallbackURL = URL(string: "https://example.com/fallback")!
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: originalURL)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(originalNavigation))

        coordinator.didStart(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(replacementNavigation),
            targetURL: fallbackURL
        )
        coordinator.didCommit(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(replacementNavigation)
        )
        coordinator.didCancel(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(originalNavigation)
        )

        #expect(await coordinator.wait(for: ticket) == .cancelled)
    }

    @Test("An authoritative same-document navigation event completes the transaction")
    func sameDocumentNavigationEventCompletes() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let navigation = NSObject()
        let targetURL = URL(string: "https://example.com/page#section")!
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(
            instanceID: instanceID,
            targetURL: targetURL,
            allowsSameDocumentCompletion: true
        )
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))

        coordinator.didFinishSameDocumentNavigation(instanceID: instanceID, url: targetURL)

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test("WebKit-canonical same-document URLs complete the transaction")
    func canonicalSameDocumentURLsComplete() async {
        let equivalents = [
            ("https://example.com#verified", "https://example.com/#verified"),
            (
                "HTTPS://EXAMPLE.COM:443/%7euser?q=%7e#part%2fvalue",
                "https://example.com/~user?q=~#part%2Fvalue"
            ),
            ("http://EXAMPLE.COM:80#verified", "http://example.com/#verified"),
        ]

        for (target, observed) in equivalents {
            let coordinator = BrowserAutomationNavigationCoordinator()
            let instanceID = UUID()
            let navigation = NSObject()
            let targetURL = URL(string: target)!
            coordinator.bind(to: instanceID)
            let ticket = coordinator.begin(
                instanceID: instanceID,
                targetURL: targetURL,
                allowsSameDocumentCompletion: true
            )
            coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))

            coordinator.didFinishSameDocumentNavigation(
                instanceID: instanceID,
                url: URL(string: observed)
            )

            #expect(await coordinator.wait(for: ticket) == .committed)
        }
    }

    @Test("Reserved escapes are not collapsed when matching same-document URLs")
    func reservedEscapeRemainsDistinct() async {
        let coordinator = BrowserAutomationNavigationCoordinator(sleep: { _ in })
        let instanceID = UUID()
        let navigation = NSObject()
        let targetURL = URL(string: "https://example.com/a%2Fb#verified")!
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(
            instanceID: instanceID,
            targetURL: targetURL,
            allowsSameDocumentCompletion: true
        )
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))

        coordinator.didFinishSameDocumentNavigation(
            instanceID: instanceID,
            url: URL(string: "https://example.com/a/b#verified")
        )

        #expect(await coordinator.wait(for: ticket) == .timedOut)
    }

    @Test("An error document cannot satisfy a navigation with a fragment event")
    func errorDocumentSameDocumentEventIsIgnored() async {
        let coordinator = BrowserAutomationNavigationCoordinator(sleep: { _ in })
        let instanceID = UUID()
        let navigation = NSObject()
        let targetURL = URL(string: "https://example.com/page#section")!
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: targetURL)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))

        coordinator.didFinishSameDocumentNavigation(instanceID: instanceID, url: targetURL)

        #expect(await coordinator.wait(for: ticket) == .timedOut)
    }

    @Test("Associating a matching load is not itself a navigation completion")
    func navigationAssociationDoesNotCompleteTransaction() async {
        let coordinator = BrowserAutomationNavigationCoordinator(sleep: { _ in })
        let instanceID = UUID()
        let navigation = NSObject()
        let targetURL = URL(string: "https://example.com/page")!
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: targetURL)

        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))

        #expect(await coordinator.wait(for: ticket) == .timedOut)
    }

    @Test("A main-frame download completes the transaction without a document commit")
    func mainFrameDownloadCompletes() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let navigation = NSObject()
        let targetURL = URL(string: "https://example.com/archive.zip")!
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: targetURL)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))

        coordinator.didChooseDownloadPolicy(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(navigation)
        )
        #expect(coordinator.didInterruptByPolicyChange(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(navigation)
        ))

        #expect(await coordinator.wait(for: ticket) == .downloaded)
    }

    @Test("An unrelated download policy cannot authorize the active transaction")
    func unrelatedDownloadPolicyIsIgnored() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let navigation = NSObject()
        let targetURL = URL(string: "https://example.com/page")!
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: targetURL)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))

        coordinator.didChooseDownloadPolicy(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(NSObject())
        )
        #expect(!coordinator.didInterruptByPolicyChange(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(navigation)
        ))

        #expect(await coordinator.wait(for: ticket) == .cancelled)
    }

    @Test("A matching URL without exact download policy identity is a cancellation")
    func urlMatchCannotAuthorizeDownload() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let navigation = NSObject()
        let targetURL = URL(string: "https://example.com/archive.zip")!
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: targetURL)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))

        #expect(!coordinator.didInterruptByPolicyChange(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(navigation)
        ))

        #expect(await coordinator.wait(for: ticket) == .cancelled)
    }

    @Test("A document-less new-tab reload can complete without WebKit navigation")
    func documentlessNewTabReloadCompletes() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)

        coordinator.didReturnNoNavigation(
            ticket,
            hasCurrentHistoryItem: false,
            isShowingNewTabPage: true,
            waitsForDeferredNavigation: false
        )

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test("A nil reload for an existing document is not reported as committed")
    func existingDocumentNilReloadIsNotStarted() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)

        coordinator.didReturnNoNavigation(
            ticket,
            hasCurrentHistoryItem: true,
            isShowingNewTabPage: false,
            waitsForDeferredNavigation: false
        )

        #expect(await coordinator.wait(for: ticket) == .notStarted)
    }

    @Test("A deferred nil reload remains pending for its real navigation")
    func deferredNilReloadBindsRealNavigation() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let navigation = NSObject()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)
        coordinator.didReturnNoNavigation(
            ticket,
            hasCurrentHistoryItem: true,
            isShowingNewTabPage: false,
            waitsForDeferredNavigation: true
        )

        coordinator.didStart(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(navigation)
        )
        coordinator.didCommit(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(navigation)
        )

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test("A load that returns no navigation terminates as not started")
    func missingNavigationIsNotStarted() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)

        coordinator.didStart(ticket, navigationID: nil)

        #expect(await coordinator.wait(for: ticket) == .notStarted)
    }

    @Test("A newer transaction supersedes the previous transaction")
    func newerTransactionSupersedesPreviousTransaction() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        coordinator.bind(to: instanceID)
        let firstTicket = coordinator.begin(instanceID: instanceID)

        _ = coordinator.begin(instanceID: instanceID)

        #expect(await coordinator.wait(for: firstTicket) == .superseded)
    }

    @Test("Binding a replacement instance supersedes the old transaction")
    func replacementSupersedesOldTransaction() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let firstInstanceID = UUID()
        coordinator.bind(to: firstInstanceID)
        let ticket = coordinator.begin(instanceID: firstInstanceID)

        coordinator.bind(to: UUID())

        #expect(await coordinator.wait(for: ticket) == .superseded)
    }
}
