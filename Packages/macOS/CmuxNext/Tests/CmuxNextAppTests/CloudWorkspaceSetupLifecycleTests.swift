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
        if result != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func wait() async -> Bool {
        await withCheckedContinuation {
            result = $0
            requested?.resume()
            requested = nil
        }
    }

    func resolve(_ value: Bool) {
        result?.resume(returning: value)
        result = nil
    }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct CloudSignedOutCreationContinuationTests {
    @Test func resumesTheCapturedIntentOnce() async {
        let handoff = CloudSignedOutCreationContinuation()
        let gate = CloudSignInTestGate()
        var intent = "original"
        var resumed: [String] = []
        let pending = handoff.replace(signIn: { await gate.wait() }, resume: { [intent] in resumed.append(intent) })
        await gate.waitUntilRequested()
        intent = "later"
        gate.resolve(true)
        await pending.value
        #expect(resumed == ["original"])
        #expect(intent == "later")
        #expect(!handoff.isPending)
    }

    @Test func replacementIgnoresLateResultFromTheOriginalIntent() async {
        let handoff = CloudSignedOutCreationContinuation()
        let first = CloudSignInTestGate()
        let second = CloudSignInTestGate()
        var resumed: [String] = []
        let old = handoff.replace(signIn: { await first.wait() }, resume: { resumed.append("old") })
        await first.waitUntilRequested()
        let latest = handoff.replace(signIn: { await second.wait() }, resume: { resumed.append("latest") })
        await second.waitUntilRequested()
        first.resolve(true)
        await old.value
        #expect(resumed.isEmpty)
        #expect(handoff.isPending)
        second.resolve(true)
        await latest.value
        #expect(resumed == ["latest"])
        #expect(!handoff.isPending)
    }

    @Test func signOutInvalidationIgnoresLateSignInResult() async {
        let handoff = CloudSignedOutCreationContinuation()
        let gate = CloudSignInTestGate()
        var resumes = 0
        let pending = handoff.replace(signIn: { await gate.wait() }, resume: { resumes += 1 })
        await gate.waitUntilRequested()
        handoff.cancel()
        gate.resolve(true)
        await pending.value
        #expect(resumes == 0)
        #expect(!handoff.isPending)
    }

    @Test func dismissedSignInNeverResumesAndClearsPendingIntent() async {
        let handoff = CloudSignedOutCreationContinuation()
        var resumes = 0
        await handoff.replace(signIn: { false }, resume: { resumes += 1 }).value
        #expect(resumes == 0)
        #expect(!handoff.isPending)
    }

    @Test func signInUserThenInitialTeamHydrationStillResumes() async {
        let handoff = CloudSignedOutCreationContinuation()
        let gate = CloudSignInTestGate()
        var resumes = 0
        let pending = handoff.replace(signIn: { await gate.wait() }, resume: { resumes += 1 })
        await gate.waitUntilRequested()
        handoff.scopeDidChange(from: [nil, nil], to: ["user", nil])
        handoff.scopeDidChange(from: ["user", nil], to: ["user", "team"])
        #expect(handoff.isPending)
        gate.resolve(true)
        await pending.value
        #expect(resumes == 1)
    }

    @Test func nilUserTeamHydrationCannotResumeAnewSignIn() async {
        let handoff = CloudSignedOutCreationContinuation()
        let gate = CloudSignInTestGate()
        var resumes = 0
        let pending = handoff.replace(signIn: { await gate.wait() }, resume: { resumes += 1 })
        await gate.waitUntilRequested()
        handoff.scopeDidChange(from: [nil, nil], to: [nil, "team"])
        gate.resolve(true)
        await pending.value
        #expect(resumes == 0)
        #expect(!handoff.isPending)
    }

    @Test func staleTeamRestorationCannotResumeAnewSignIn() async {
        let handoff = CloudSignedOutCreationContinuation()
        let gate = CloudSignInTestGate()
        var resumes = 0
        let pending = handoff.replace(signIn: { await gate.wait() }, resume: { resumes += 1 })
        await gate.waitUntilRequested()
        handoff.scopeDidChange(from: [nil, "old-team"], to: ["new-user", "new-team"])
        gate.resolve(true)
        await pending.value
        #expect(resumes == 0)
        #expect(!handoff.isPending)
    }

    @Test(arguments: [["other", "team"], ["user", "other"], ["user", nil], [nil, nil]])
    func accountOrTeamReplacementInvalidatesPendingSignIn(current: [String?]) async {
        let handoff = CloudSignedOutCreationContinuation()
        let gate = CloudSignInTestGate()
        var resumes = 0
        let pending = handoff.replace(signIn: { await gate.wait() }, resume: { resumes += 1 })
        await gate.waitUntilRequested()
        handoff.scopeDidChange(from: ["user", "team"], to: current)
        gate.resolve(true)
        await pending.value
        #expect(resumes == 0)
        #expect(!handoff.isPending)
    }

    @Test func cancelledWaiterCannotResumeEvenIfAuthSucceeded() async {
        let handoff = CloudSignedOutCreationContinuation()
        let gate = CloudSignInTestGate()
        var resumes = 0
        let pending = handoff.replace(signIn: { await gate.wait() }, resume: { resumes += 1 })
        await gate.waitUntilRequested()
        pending.cancel()
        gate.resolve(true)
        await pending.value
        #expect(resumes == 0)
        #expect(!handoff.isPending)
    }
}
