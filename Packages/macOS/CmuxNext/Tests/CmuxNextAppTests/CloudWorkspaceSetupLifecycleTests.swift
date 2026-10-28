@testable import CmuxNextApp
import CmuxNextCloudUI
import CmuxNextCompat
import Testing

@MainActor @Suite(.timeLimit(.minutes(1)))
struct CloudWorkspaceSetupLifecycleTests {
    @Test func failedAttemptCanRetryAndOpenItsWorkspace() async {
        let creations = CloudCreations()
        let creation = creations.begin(window: nil)
        creation.note(.failed("Connection failed"))
        #expect(CloudHandlers.workspaceSetupReadiness(creation, in: creations) == .waiting)
        creation.restart()
        #expect(CloudHandlers.workspaceSetupReadiness(creation, in: creations) == .waiting)
        var events = ObservationStream { CloudHandlers.workspaceSetupReadiness(creation, in: creations) }.makeAsyncIterator()
        let waiting = await events.next()
        #expect(waiting == CloudWorkspaceSetupWizard.Readiness.waiting)
        creation.opened("workspace")
        let ready = await events.next()
        #expect(ready == .ready)
    }

    @Test func dismissedAttemptEndsReadinessObservation() async {
        let creations = CloudCreations()
        let creation = creations.begin(window: nil)
        var events = ObservationStream { CloudHandlers.workspaceSetupReadiness(creation, in: creations) }.makeAsyncIterator()
        _ = await events.next()
        creations.end(creation)
        let ended = await events.next()
        #expect(ended == .ended)
    }

    @Test func mirroredRowKeepsCloneWaitButTeardownWakesIt() async {
        let creations = CloudCreations()
        let creation = creations.begin(window: nil)
        creation.opened("workspace")
        creations.remove(creation)
        #expect(CloudHandlers.workspaceSetupReadiness(creation, in: creations) == .ready)
        var events = ObservationStream { CloudHandlers.workspaceSetupCompletion(creation) }.makeAsyncIterator()
        let initial = await events.next()
        #expect(initial?.completion == nil)
        #expect(initial?.ended == false)
        creation.tearDown()
        let ended = await events.next()
        #expect(ended?.completion == nil)
        #expect(ended?.ended == true)
        #expect(CloudHandlers.workspaceSetupReadiness(creation, in: creations) == .ended)
    }

    @Test func accountChangeTearsDownBeforeMachineAttach() {
        let creations = CloudCreations()
        let creation = creations.begin(window: nil)
        do {
            try CloudHandlers.checkCreationScope(creation, in: creations, expectedUserID: "before", expectedTeamID: "team",
                                                 currentUserID: "after", currentTeamID: "team")
            Issue.record("scope check unexpectedly passed")
        } catch is CancellationError {
            // Expected: the create response must not attach after an account switch.
        } catch {
            Issue.record("unexpected scope-check error: \(error)")
        }
        #expect(creation.isTornDown)
        #expect(creations.creation(creation.id) == nil)
        #expect(CloudHandlers.workspaceSetupReadiness(creation, in: creations) == .ended)
    }
}

@MainActor
private final class CloudSignInTestGate {
    private var result: CheckedContinuation<Bool, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func waitUntilRequested() async {
        await withCheckedContinuation { requested = $0 }
    }

    func wait() async -> Bool {
        requested?.resume()
        requested = nil
        return await withCheckedContinuation { result = $0 }
    }

    func resolve(_ value: Bool) {
        result?.resume(returning: value)
        result = nil
    }
}

@MainActor @Suite(.serialized)
struct CloudSignedOutCreationContinuationTests {
    @Test func resumesExactlyOnceAfterSignIn() async {
        let handoff = CloudSignedOutCreationContinuation()
        let gate = CloudSignInTestGate()
        var resumes = 0
        handoff.replace(signIn: { await gate.wait() }, resume: { resumes += 1 })
        await gate.waitUntilRequested()
        gate.resolve(true)
        while resumes == 0 { await Task.yield() }
        #expect(resumes == 1)
    }

    @Test func replacementIgnoresLateResultFromTheOriginalIntent() async {
        let handoff = CloudSignedOutCreationContinuation()
        let first = CloudSignInTestGate()
        let second = CloudSignInTestGate()
        var resumes = 0
        handoff.replace(signIn: { await first.wait() }, resume: { resumes += 1 })
        await first.waitUntilRequested()
        handoff.replace(signIn: { await second.wait() }, resume: { resumes += 1 })
        await second.waitUntilRequested()
        first.resolve(true)
        await Task.yield()
        #expect(resumes == 0)
        second.resolve(true)
        while resumes == 0 { await Task.yield() }
        #expect(resumes == 1)
    }

    @Test func cancellationIgnoresLateSignInResult() async {
        let handoff = CloudSignedOutCreationContinuation()
        let gate = CloudSignInTestGate()
        var resumes = 0
        handoff.replace(signIn: { await gate.wait() }, resume: { resumes += 1 })
        await gate.waitUntilRequested()
        handoff.cancel()
        gate.resolve(true)
        await Task.yield()
        #expect(resumes == 0)
        #expect(!handoff.isPending)
    }
}
