import Foundation
import CmuxFoundation
import Observation

/// Shared, observable Low Power UI state. Sleepy Mode creates one overlay window
/// per display; injecting a single instance into every `SleepyFaceView` keeps
/// their labels in sync and makes each button compute its next action from one
/// authoritative value (instead of per-window `@State` that goes stale when
/// another display toggles).
@MainActor
@Observable
final class SleepyPowerUIState {
    private static let lockTaskKey = "sleepyMode.lock"

    private var sessionID = UUID()
    private var nextLockRequestID: UInt64 = 0
    private var activeLockRequestID: UInt64?
    @ObservationIgnored private var lockInvocationGate: SleepyLockInvocationGate?
    @ObservationIgnored private let lockTaskStore = MainActorTaskStore<String>()

    /// Whether Low Power Mode is currently on (last re-read from the system).
    var isOn = false
    /// Whether a privileged toggle is in flight (disables the button).
    var isBusy = false
    /// True after a Lock Mac attempt reported failure, so the overlay tells the
    /// user instead of silently staying unlocked (the failure mode of
    /// https://github.com/manaflow-ai/cmux/issues/9730). Cleared when a later
    /// attempt confirms the lock or a new Sleepy Mode session begins.
    var lockFailed = false

    /// Starts a fresh overlay session and clears transient lock feedback.
    func beginSession() {
        cancelLockRequest()
        sessionID = UUID()
        lockFailed = false
    }

    /// Whether a Lock Mac request is currently in flight.
    var isLockBusy: Bool {
        activeLockRequestID != nil
    }

    /// Starts one lock request and returns its session/request identity.
    /// Concurrent overlay buttons share this gate, so an older result cannot
    /// overwrite a newer request's outcome.
    func beginLockRequest() -> SleepyLockRequest? {
        guard activeLockRequestID == nil else { return nil }
        nextLockRequestID &+= 1
        activeLockRequestID = nextLockRequestID
        return SleepyLockRequest(sessionID: sessionID, requestID: nextLockRequestID)
    }

    /// Runs a request through the lifecycle-owned task store. Cancelling the
    /// current session or deactivating Sleepy Mode cancels this operation before
    /// it can publish a stale result.
    func runLockRequest(_ request: SleepyLockRequest, using power: any SleepyPowerControlling) {
        guard request.sessionID == sessionID,
              activeLockRequestID == request.requestID else { return }

        let gate = SleepyLockInvocationGate()
        lockInvocationGate = gate
        lockTaskStore.replaceOnMainActor(Self.lockTaskKey) { [weak self] in
            guard !Task.isCancelled else { return }
            let issued = await power.lockMacNow(using: gate)
            guard !Task.isCancelled else { return }
            self?.recordLockResult(
                issued,
                for: request.sessionID,
                requestID: request.requestID
            )
        }
    }

    /// Cancels an in-flight request at the Sleepy Mode lifecycle boundary.
    func cancelLockRequest() {
        if let gate = lockInvocationGate {
            gate.cancel()
            lockInvocationGate = nil
        }
        lockTaskStore.cancel(Self.lockTaskKey)
        activeLockRequestID = nil
    }

    /// Records the lock confirmation only when both the Sleepy session and
    /// request identity are still current.
    func recordLockResult(
        _ confirmed: Bool,
        for attemptedSessionID: UUID,
        requestID: UInt64
    ) {
        guard attemptedSessionID == sessionID,
              activeLockRequestID == requestID else { return }
        activeLockRequestID = nil
        lockFailed = !confirmed
    }
}
