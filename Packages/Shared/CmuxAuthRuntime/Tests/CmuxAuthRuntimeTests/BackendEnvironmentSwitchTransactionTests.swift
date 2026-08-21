import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Records step invocations and lets a test park the park/prompt steps on
/// continuations to probe the transaction's ordering guarantees.
@MainActor
private final class StepRecorder {
    private(set) var events: [String] = []
    private(set) var storedOverrides: [CMUXBackendEnvironmentOverride] = []
    private(set) var rebuiltOverrides: [CMUXBackendEnvironmentOverride] = []
    var pinned = false
    var active: CMUXBackendEnvironmentOverride = .production

    /// The user `awaitRestoredUser` resolves per call (consumed head-first;
    /// empty = nil). The revert's trailing restore also consumes one.
    var restoredUsers: [CMUXAuthUser?] = [nil]
    /// The user `promptSignIn` resolves.
    var promptedUser: CMUXAuthUser?
    /// The eligibility verdict per user id (default: ineligible).
    var eligibleUserIDs: Set<String> = []
    /// The platform classification of a nil prompt.
    var promptFailure: BackendEnvironmentSwitchTransaction.SignInPromptFailure = .failed

    private var parkGate: CheckedContinuation<Void, Never>?
    var parkPark = false
    private(set) var parkParked = false

    private var promptGate: CheckedContinuation<CMUXAuthUser?, Never>?
    var parkPrompt = false
    private(set) var promptParked = false

    func releasePark() {
        parkParked = false
        parkGate?.resume()
        parkGate = nil
    }

    /// Resolve a parked prompt with `user` (nil = cancel/failure).
    func resolvePrompt(with user: CMUXAuthUser?) {
        promptParked = false
        promptGate?.resume(returning: user)
        promptGate = nil
    }

    func steps() -> BackendEnvironmentSwitchTransaction.Steps {
        BackendEnvironmentSwitchTransaction.Steps(
            isPinnedByBuild: { self.pinned },
            activeEnvironment: { self.active },
            parkSession: {
                self.events.append("park")
                if self.parkPark {
                    self.parkParked = true
                    await withCheckedContinuation { self.parkGate = $0 }
                }
            },
            quiesce: { self.events.append("quiesce") },
            storeOverride: { target in
                self.events.append("store(\(target.rawValue))")
                self.storedOverrides.append(target)
            },
            rebuild: { target in
                self.events.append("rebuild(\(target.rawValue))")
                self.rebuiltOverrides.append(target)
            },
            awaitRestoredUser: {
                self.events.append("awaitRestoredUser")
                guard !self.restoredUsers.isEmpty else { return nil }
                return self.restoredUsers.removeFirst()
            },
            promptSignIn: {
                self.events.append("promptSignIn")
                if self.parkPrompt {
                    self.promptParked = true
                    return await withCheckedContinuation { self.promptGate = $0 }
                }
                return self.promptedUser
            },
            cancelSignInPrompt: {
                self.events.append("cancelSignInPrompt")
                self.resolvePrompt(with: nil)
            },
            signOutEstablishedSession: { self.events.append("signOutEstablished") },
            isEligible: { user in
                self.events.append("isEligible(\(user.id))")
                return self.eligibleUserIDs.contains(user.id)
            },
            signInPromptFailure: { self.promptFailure }
        )
    }
}

@MainActor
@Suite("Backend environment switch transaction")
struct BackendEnvironmentSwitchTransactionTests {
    private static let teamUser = CMUXAuthUser(
        id: "team-user",
        primaryEmail: "aziz@manaflow.ai",
        displayName: "Aziz"
    )
    private static let outsideUser = CMUXAuthUser(
        id: "outside-user",
        primaryEmail: "someone@example.com",
        displayName: "Someone"
    )

    @Test("Override is not stored until the park completes, and steps run in order")
    func orderingHazard() async {
        let recorder = StepRecorder()
        recorder.parkPark = true
        recorder.restoredUsers = [Self.teamUser]
        recorder.eligibleUserIDs = [Self.teamUser.id]
        let transaction = BackendEnvironmentSwitchTransaction()

        let run = Task { await transaction.run(to: .staging, steps: recorder.steps()) }
        while !recorder.parkParked { await Task.yield() }

        #expect(recorder.events == ["park"])
        #expect(recorder.storedOverrides.isEmpty)
        #expect(transaction.phase == .parking)

        recorder.releasePark()
        await run.value

        #expect(recorder.events == [
            "park", "quiesce", "store(staging)", "rebuild(staging)",
            "awaitRestoredUser", "isEligible(team-user)",
        ])
        #expect(recorder.storedOverrides == [.staging])
        #expect(transaction.phase == .finished(.switched))
    }

    @Test("A restored eligible session completes the switch with zero prompt")
    func restoredEligibleSkipsPrompt() async {
        let recorder = StepRecorder()
        recorder.restoredUsers = [Self.teamUser]
        recorder.eligibleUserIDs = [Self.teamUser.id]
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .staging, steps: recorder.steps())

        #expect(transaction.phase == .finished(.switched))
        #expect(!recorder.events.contains("promptSignIn"))
        #expect(!recorder.events.contains("signOutEstablished"))
    }

    @Test("A restored ineligible session is signed out for real, then prompted")
    func restoredIneligibleSignsOutThenPrompts() async {
        let recorder = StepRecorder()
        recorder.restoredUsers = [Self.outsideUser]
        recorder.promptedUser = Self.teamUser
        recorder.eligibleUserIDs = [Self.teamUser.id]
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .staging, steps: recorder.steps())

        #expect(transaction.phase == .finished(.switched))
        let signOuts = recorder.events.filter { $0 == "signOutEstablished" }
        #expect(signOuts.count == 1)
        // The real sign-out lands BEFORE the prompt (under target defaults).
        let signOutIndex = recorder.events.firstIndex(of: "signOutEstablished")
        let promptIndex = recorder.events.firstIndex(of: "promptSignIn")
        #expect(signOutIndex != nil && promptIndex != nil && signOutIndex! < promptIndex!)
    }

    @Test("No parked session prompts inline; an eligible sign-in switches")
    func noSessionPromptsInline() async {
        let recorder = StepRecorder()
        recorder.restoredUsers = [nil]
        recorder.promptedUser = Self.teamUser
        recorder.eligibleUserIDs = [Self.teamUser.id]
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .staging, steps: recorder.steps())

        #expect(transaction.phase == .finished(.switched))
        #expect(recorder.events.contains("promptSignIn"))
        #expect(!recorder.events.contains("signOutEstablished"))
    }

    @Test("An ineligible prompted user signs out exactly once and reverts(.notEligible)")
    func ineligiblePromptRevertsWithOneRealSignOut() async {
        let recorder = StepRecorder()
        recorder.restoredUsers = [nil, nil]
        recorder.promptedUser = Self.outsideUser
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .staging, steps: recorder.steps())

        #expect(transaction.phase == .finished(.reverted(.notEligible)))
        #expect(recorder.events.filter { $0 == "signOutEstablished" }.count == 1)
        // Revert order: quiesce → store(previous) → rebuild(previous) →
        // awaitRestoredUser.
        let suffix = Array(recorder.events.drop(while: { $0 != "signOutEstablished" }).dropFirst())
        #expect(suffix == ["quiesce", "store(production)", "rebuild(production)", "awaitRestoredUser"])
        #expect(recorder.storedOverrides == [.staging, .production])
    }

    @Test("A cancelled prompt reverts(.signInCancelled)")
    func cancelledPromptReverts() async {
        let recorder = StepRecorder()
        recorder.restoredUsers = [nil, nil]
        recorder.promptedUser = nil
        recorder.promptFailure = .cancelled
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .staging, steps: recorder.steps())

        #expect(transaction.phase == .finished(.reverted(.signInCancelled)))
        #expect(recorder.storedOverrides == [.staging, .production])
        #expect(recorder.rebuiltOverrides == [.staging, .production])
    }

    @Test("A failed prompt reverts(.signInFailed)")
    func failedPromptReverts() async {
        let recorder = StepRecorder()
        recorder.restoredUsers = [nil, nil]
        recorder.promptedUser = nil
        recorder.promptFailure = .failed
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .staging, steps: recorder.steps())

        #expect(transaction.phase == .finished(.reverted(.signInFailed)))
    }

    @Test("PIN: a production target never consults the gate or the prompt")
    func productionNeverGates() async {
        let recorder = StepRecorder()
        recorder.active = .staging
        // Even a restored INELIGIBLE user must complete the switch silently.
        recorder.restoredUsers = [Self.outsideUser]
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .production, steps: recorder.steps())

        #expect(transaction.phase == .finished(.switched))
        #expect(!recorder.events.contains("promptSignIn"))
        #expect(!recorder.events.contains { $0.hasPrefix("isEligible") })
        #expect(!recorder.events.contains("signOutEstablished"))
    }

    @Test("PIN: a revert never gates and never prompts, so it cannot loop")
    func revertNeverPrompts() async {
        let recorder = StepRecorder()
        recorder.restoredUsers = [nil, Self.outsideUser]
        recorder.promptedUser = nil
        recorder.promptFailure = .failed
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .staging, steps: recorder.steps())

        // One prompt total (the staging establish); the revert's trailing
        // restore returned an ineligible user and STILL finished reverted
        // without consulting the gate or prompting again.
        #expect(transaction.phase == .finished(.reverted(.signInFailed)))
        #expect(recorder.events.filter { $0 == "promptSignIn" }.count == 1)
        #expect(recorder.events.filter { $0.hasPrefix("isEligible") }.isEmpty)
    }

    @Test("requestRevert during the prompt cancels it and reverts(.signInCancelled)")
    func requestRevertCancelsPrompt() async {
        let recorder = StepRecorder()
        recorder.restoredUsers = [nil, nil]
        recorder.parkPrompt = true
        let transaction = BackendEnvironmentSwitchTransaction()

        let run = Task { await transaction.run(to: .staging, steps: recorder.steps()) }
        while !recorder.promptParked { await Task.yield() }
        #expect(transaction.phase == .establishing)

        transaction.requestRevert()
        await run.value

        #expect(recorder.events.contains("cancelSignInPrompt"))
        #expect(transaction.phase == .finished(.reverted(.signInCancelled)))
    }

    @Test("requestRevert outside establishing is a no-op")
    func requestRevertOutsideEstablishingIsNoOp() async {
        let recorder = StepRecorder()
        let transaction = BackendEnvironmentSwitchTransaction()
        transaction.requestRevert()
        #expect(transaction.phase == .idle)
        #expect(recorder.events.isEmpty)
    }

    @Test("A concurrent run joins the active one instead of double-switching")
    func reentrancyJoins() async {
        let recorder = StepRecorder()
        recorder.parkPark = true
        recorder.restoredUsers = [Self.teamUser]
        recorder.eligibleUserIDs = [Self.teamUser.id]
        let transaction = BackendEnvironmentSwitchTransaction()

        let first = Task { await transaction.run(to: .staging, steps: recorder.steps()) }
        while !recorder.parkParked { await Task.yield() }
        let second = Task { await transaction.run(to: .staging, steps: recorder.steps()) }

        recorder.releasePark()
        await first.value
        await second.value

        #expect(recorder.storedOverrides == [.staging])
        #expect(recorder.events.filter { $0.hasPrefix("rebuild") }.count == 1)
    }

    @Test("Pinned builds cannot start the transaction")
    func pinnedRefusal() async {
        let recorder = StepRecorder()
        recorder.pinned = true
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .staging, steps: recorder.steps())

        #expect(recorder.events.isEmpty)
        #expect(transaction.phase == .idle)
    }

    @Test("Switching to the already-active environment is a no-op")
    func noOpRefusal() async {
        let recorder = StepRecorder()
        recorder.active = .staging
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .staging, steps: recorder.steps())

        #expect(recorder.events.isEmpty)
        #expect(transaction.phase == .idle)
    }

    @Test("Production is switchable back after a finished staging switch")
    func switchBackAfterFinish() async {
        let recorder = StepRecorder()
        recorder.restoredUsers = [Self.teamUser, Self.teamUser]
        recorder.eligibleUserIDs = [Self.teamUser.id]
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .staging, steps: recorder.steps())
        #expect(transaction.phase == .finished(.switched))

        recorder.active = .staging
        await transaction.run(to: .production, steps: recorder.steps())

        #expect(recorder.storedOverrides == [.staging, .production])
        #expect(transaction.phase == .finished(.switched))
    }

    @Test("Reset returns to idle only from finished")
    func resetSemantics() async {
        let transaction = BackendEnvironmentSwitchTransaction()
        transaction.reset()
        #expect(transaction.phase == .idle)

        let recorder = StepRecorder()
        recorder.restoredUsers = [Self.teamUser]
        recorder.eligibleUserIDs = [Self.teamUser.id]
        await transaction.run(to: .staging, steps: recorder.steps())
        #expect(transaction.phase == .finished(.switched))
        transaction.reset()
        #expect(transaction.phase == .idle)
    }
}
