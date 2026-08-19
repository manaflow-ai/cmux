import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Records step invocations and lets a test park the sign-out step on a
/// continuation to probe the transaction's ordering guarantees.
@MainActor
private final class StepRecorder {
    private(set) var events: [String] = []
    private(set) var storedOverrides: [CMUXBackendEnvironmentOverride] = []
    var pinned = false
    var active: CMUXBackendEnvironmentOverride = .production

    private var signOutGate: CheckedContinuation<Void, Never>?
    var parkSignOut = false
    private(set) var signOutParked = false

    func releaseSignOut() {
        signOutParked = false
        signOutGate?.resume()
        signOutGate = nil
    }

    func steps() -> BackendEnvironmentSwitchTransaction.Steps {
        BackendEnvironmentSwitchTransaction.Steps(
            isPinnedByBuild: { self.pinned },
            activeEnvironment: { self.active },
            signOut: {
                self.events.append("signOut")
                if self.parkSignOut {
                    self.signOutParked = true
                    await withCheckedContinuation { self.signOutGate = $0 }
                }
            },
            quiesce: { self.events.append("quiesce") },
            storeOverride: { target in
                self.events.append("store")
                self.storedOverrides.append(target)
            },
            rebuild: { _ in self.events.append("rebuild") }
        )
    }
}

@MainActor
@Suite("Backend environment switch transaction")
struct BackendEnvironmentSwitchTransactionTests {
    @Test("Override is not stored until sign-out completes, and steps run in order")
    func orderingHazard() async {
        let recorder = StepRecorder()
        recorder.parkSignOut = true
        let transaction = BackendEnvironmentSwitchTransaction()

        let run = Task { await transaction.run(to: .staging, steps: recorder.steps()) }
        while !recorder.signOutParked { await Task.yield() }

        #expect(recorder.events == ["signOut"])
        #expect(recorder.storedOverrides.isEmpty)
        #expect(transaction.phase == .signingOut)

        recorder.releaseSignOut()
        await run.value

        #expect(recorder.events == ["signOut", "quiesce", "store", "rebuild"])
        #expect(recorder.storedOverrides == [.staging])
        #expect(transaction.phase == .finished)
    }

    @Test("A concurrent run joins the active one instead of double-switching")
    func reentrancyJoins() async {
        let recorder = StepRecorder()
        recorder.parkSignOut = true
        let transaction = BackendEnvironmentSwitchTransaction()

        let first = Task { await transaction.run(to: .staging, steps: recorder.steps()) }
        while !recorder.signOutParked { await Task.yield() }
        let second = Task { await transaction.run(to: .staging, steps: recorder.steps()) }

        recorder.releaseSignOut()
        await first.value
        await second.value

        #expect(recorder.storedOverrides == [.staging])
        #expect(recorder.events.filter { $0 == "rebuild" }.count == 1)
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
        let transaction = BackendEnvironmentSwitchTransaction()

        await transaction.run(to: .staging, steps: recorder.steps())
        #expect(transaction.phase == .finished)

        recorder.active = .staging
        await transaction.run(to: .production, steps: recorder.steps())

        #expect(recorder.storedOverrides == [.staging, .production])
        #expect(transaction.phase == .finished)
    }

    @Test("Reset returns to idle only from finished")
    func resetSemantics() async {
        let transaction = BackendEnvironmentSwitchTransaction()
        transaction.reset()
        #expect(transaction.phase == .idle)

        let recorder = StepRecorder()
        await transaction.run(to: .staging, steps: recorder.steps())
        #expect(transaction.phase == .finished)
        transaction.reset()
        #expect(transaction.phase == .idle)
    }
}
