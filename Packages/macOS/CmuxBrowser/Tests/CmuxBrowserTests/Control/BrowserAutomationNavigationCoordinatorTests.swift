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

    @Test("A policy replacement hands the transaction to the new navigation")
    func policyReplacementHandsOffNavigationIdentity() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let originalNavigation = NSObject()
        let replacementNavigation = NSObject()
        let originalURL = URL(string: "https://example.com/launch")!
        let fallbackURL = URL(string: "https://example.com/fallback")!
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: originalURL)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(originalNavigation))

        #expect(coordinator.prepareForNavigationReplacement(
            instanceID: instanceID,
            targetURL: fallbackURL
        ))
        coordinator.didCancel(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(originalNavigation)
        )
        coordinator.didStart(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(replacementNavigation)
        )
        coordinator.didCommit(
            instanceID: instanceID,
            navigationID: ObjectIdentifier(replacementNavigation)
        )

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test("An authoritative same-document URL change completes the transaction")
    func sameDocumentURLChangeCompletes() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        let navigation = NSObject()
        let targetURL = URL(string: "https://example.com/page#section")!
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: targetURL)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(navigation))

        coordinator.didReachSameDocumentURL(instanceID: instanceID, url: targetURL)

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test("A URL-less reload can complete without starting WebKit navigation")
    func reloadWithoutNavigationCompletes() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        coordinator.bind(to: instanceID)
        let ticket = coordinator.begin(instanceID: instanceID)

        coordinator.didCompleteWithoutNavigation(ticket)

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
