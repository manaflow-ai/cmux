import Foundation
import Testing

@testable import CmuxBrowser

@MainActor
@Suite("Browser automation document readiness")
struct BrowserAutomationDocumentReadinessTests {
    @Test("A document committed before delegate binding is immediately ready")
    func precommittedInstanceIsReady() async {
        let readiness = BrowserAutomationDocumentReadiness()
        let instanceID = UUID()

        readiness.bind(to: instanceID, hasCommittedDocument: true)

        #expect(readiness.hasCommittedDocument(for: instanceID))
        #expect(await readiness.waitForCommit(instanceID: instanceID) == .committed)
    }

    @Test("A navigation commit releases automation waiting on the same instance")
    func matchingCommitReleasesWaiter() async {
        let readiness = BrowserAutomationDocumentReadiness()
        let instanceID = UUID()
        readiness.bind(to: instanceID, hasCommittedDocument: false)

        let wait = Task { @MainActor in
            await readiness.waitForCommit(instanceID: instanceID)
        }
        readiness.didCommit(instanceID: instanceID)

        #expect(await wait.value == .committed)
        #expect(readiness.hasCommittedDocument(for: instanceID))
    }

    @Test("Replacing a browser instance supersedes its pending automation wait")
    func replacementSupersedesWaiter() async {
        let readiness = BrowserAutomationDocumentReadiness()
        let firstInstanceID = UUID()
        let secondInstanceID = UUID()
        readiness.bind(to: firstInstanceID, hasCommittedDocument: false)

        let wait = Task { @MainActor in
            await readiness.waitForCommit(instanceID: firstInstanceID)
        }
        readiness.bind(to: secondInstanceID, hasCommittedDocument: false)

        #expect(await wait.value == .superseded)
        #expect(!readiness.hasCommittedDocument(for: firstInstanceID))
        #expect(!readiness.hasCommittedDocument(for: secondInstanceID))
    }

    @Test("A stale navigation commit cannot ready the replacement instance")
    func staleCommitIsIgnored() {
        let readiness = BrowserAutomationDocumentReadiness()
        let firstInstanceID = UUID()
        let secondInstanceID = UUID()
        readiness.bind(to: firstInstanceID, hasCommittedDocument: false)
        readiness.bind(to: secondInstanceID, hasCommittedDocument: false)

        readiness.didCommit(instanceID: firstInstanceID)

        #expect(!readiness.hasCommittedDocument(for: firstInstanceID))
        #expect(!readiness.hasCommittedDocument(for: secondInstanceID))
    }

    @Test("Cancelling a commit wait releases it without changing readiness")
    func cancellationReleasesWaiter() async {
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let readiness = BrowserAutomationDocumentReadiness()
        let instanceID = UUID()
        readiness.bind(to: instanceID, hasCommittedDocument: false)

        let wait = Task { @MainActor in
            // This synchronous signal and same-actor call form one run-to-suspension
            // region: the test cannot resume until the readiness waiter is registered.
            registrationContinuation.yield()
            return await readiness.waitForCommit(instanceID: instanceID)
        }
        let registered: Void? = await registrationIterator.next()
        #expect(registered != nil)
        wait.cancel()

        #expect(await wait.value == .cancelled)
        #expect(!readiness.hasCommittedDocument(for: instanceID))
        registrationContinuation.finish()
    }

    @Test("Invalidating document readiness cancels a pending commit wait")
    func invalidationCancelsWaiter() async {
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let readiness = BrowserAutomationDocumentReadiness()
        let instanceID = UUID()
        readiness.bind(to: instanceID, hasCommittedDocument: false)

        let wait = Task { @MainActor in
            registrationContinuation.yield()
            return await readiness.waitForCommit(instanceID: instanceID)
        }
        let registered: Void? = await registrationIterator.next()
        #expect(registered != nil)
        readiness.invalidate()

        #expect(await wait.value == .cancelled)
        #expect(!readiness.hasCommittedDocument(for: instanceID))
        #expect(await readiness.waitForCommit(instanceID: instanceID) == .superseded)
        registrationContinuation.finish()
    }
}
