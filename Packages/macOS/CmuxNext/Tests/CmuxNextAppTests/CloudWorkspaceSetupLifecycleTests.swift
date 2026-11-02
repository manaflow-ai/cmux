@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextCloud
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

    @Test func retryAfterCopyFailureClearsTheFailureOnItsExistingMachine() {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-copy-retry")
        let creation = CloudMachineCreation(windowID: nil, session: session)
        creation.fail(ActionFailure(message: "copy failed"))
        #expect(creation.stage.failure != nil)
        creation.restart()
        #expect(creation.phase == .created)
        #expect(creation.stageInput.creation == .created)
        #expect(creation.session === session)
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
    @Test func creationEffectOwnsPostAuthWorkAndPreservesResult() async throws {
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "test.create", title: "Create", category: .other)])
        let gate = CloudSignInTestGate()
        var starts = 0
        registry.bindEffect("test.create") { _ in
            registry.trackedWorkEffect(cancellationFailure: ActionWorkFailure("cancelled"), authorize: { nil }) {
                starts += 1
                registry.track(result: Task {
                    _ = await gate.wait()
                    return .success(["machine_id": .string("created"), "pending": .bool(true)])
                })
                return nil
            }
        }
        let captured = registry.capturingRun { registry.perform("test.create") }
        #expect(starts == 0, "creation cannot start inside the synchronous handler")
        #expect(captured.results.count == 1)
        await gate.waitUntilRequested()
        #expect(starts == 1)
        gate.resolve(true)
        for work in captured.work { #expect(await work.value == nil) }
        let result = try #require(captured.results.first)
        guard case .success(let fields) = await result.value else {
            Issue.record("creation result was lost")
            return
        }
        #expect(fields["machine_id"] == .string("created"))
        #expect(fields["pending"] == .bool(true))
    }

    @Test(arguments: ["window closed", "cloud unavailable"])
    func postAuthDestinationFailureReachesRegistry(reason: String) async throws {
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "test.create", title: "Create", category: .other)])
        let handoff = CloudSignedOutCreationContinuation()
        var creations = 0
        registry.bindEffect("test.create") { _ in
            let expected = handoff.reserve()
            return registry.trackedWorkEffect(cancellationFailure: ActionWorkFailure("cancelled"), authorize: {
                let signedIn = await handoff.perform(expected: expected, signIn: { true }, resume: {})
                return signedIn ? nil : ActionWorkFailure("sign-in failed")
            }) {
                guard reason.isEmpty else { return ActionWorkFailure(refusal: .unavailable, reason: reason) }
                creations += 1
                return nil
            }
        }
        let captured = registry.capturingRun { registry.perform("test.create") }
        for work in captured.work { #expect(await work.value?.message == reason) }
        #expect(creations == 0)
        #expect(!handoff.isPending)
    }

    @Test func cancellingCreationEffectCancelsItsTrackedWork() async throws {
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "test.create", title: "Create", category: .other)])
        let gate = CloudSignInTestGate()
        var child: ActionWork?
        registry.bindEffect("test.create") { _ in
            registry.trackedWorkEffect(cancellationFailure: ActionWorkFailure("cancelled")) {
                let task: ActionWork = Task {
                    _ = await gate.wait()
                    return Task.isCancelled ? ActionWorkFailure("cancelled") : nil
                }
                child = task
                registry.track(task)
                return nil
            }
        }
        let work = registry.capturingWork { registry.perform("test.create") }
        await gate.waitUntilRequested()
        for task in work { task.cancel() }
        gate.resolve(true)
        for task in work { #expect(await task.value != nil) }
        #expect(try #require(child).isCancelled)
    }

    @Test func registryOwnsSignInAndReportsFailure() async throws {
        let handoff = CloudSignedOutCreationContinuation()
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "test.create", title: "Create", category: .other)])
        var signIns = 0, resumes = 0
        registry.bindEffect("test.create") { _ in
            handoff.effect(signIn: { signIns += 1; return false }, resume: { resumes += 1 })
        }
        let work = registry.capturingWork { registry.perform("test.create") }
        #expect(signIns == 0)
        #expect(work.count == 1)
        #expect(registry.waitingRuns["test.create"]?[.network] == 1)
        let pending = try #require(work.first)
        #expect(await pending.value != nil)
        #expect(signIns == 1)
        #expect(resumes == 0)
        #expect(!handoff.isPending)
    }

    @Test func cancelledRegistryWorkReportsFailureAndNeverReplays() async throws {
        let handoff = CloudSignedOutCreationContinuation()
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "test.create", title: "Create", category: .other)])
        let gate = CloudSignInTestGate()
        var resumes = 0
        registry.bindEffect("test.create") { _ in
            handoff.effect(signIn: { await gate.wait() }, resume: { resumes += 1 })
        }
        let pending = try #require(registry.capturingWork { registry.perform("test.create") }.first)
        await gate.waitUntilRequested()
        pending.cancel()
        gate.resolve(true)
        #expect(await pending.value != nil)
        #expect(resumes == 0)
        #expect(!handoff.isPending)
    }

    @Test func replacedReservationNeverStartsAuthentication() async {
        let handoff = CloudSignedOutCreationContinuation()
        let old = handoff.reserve()
        _ = handoff.reserve()
        var signIns = 0
        let resumed = await handoff.perform(expected: old, signIn: { signIns += 1; return true }, resume: {})
        #expect(!resumed)
        #expect(signIns == 0)
        #expect(handoff.isPending)
        handoff.cancel()
    }

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

/// Tests own their auth tasks; production work is started by ActionRegistry.
@MainActor
private extension CloudSignedOutCreationContinuation {
    func replace(signIn: @escaping @MainActor () async -> Bool,
                 resume: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let expected = reserve()
        return Task { _ = await perform(expected: expected, signIn: signIn, resume: resume) }
    }

    func effect(signIn: @escaping @MainActor () async -> Bool,
                resume: @escaping @MainActor () -> Void) -> ActionEffect {
        let expected = reserve()
        // action-wait-allow: exercise the registry-owned authentication wait.
        return .waiting(.network) {
            let resumed = await self.perform(expected: expected, signIn: signIn, resume: resume)
            return resumed ? nil : ActionWorkFailure("sign-in failed")
        }
    }
}
