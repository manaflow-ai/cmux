import CmuxNextWakeups
import Foundation

/// A restart of a conversation owner that may run only while the owner is idle
/// (`OwnerIdleProbe`): a DEV app's one install-key restart of its keyless Chief
/// owner (cx-ebm.59.5). `attempt` tries at once. While the owner is busy, `note`
/// tries again on each owner event that can end the business: a client left or
/// changed its kind (an open `cmux chief` chat ends, another app or a page
/// disconnects) or a typing set changed (a Chief turn ends). It restarts at most once.
/// A `cmux` CLI or MCP call in flight (a local client without a kind) ends with a
/// `client-detached`; a standing connection without a kind sends no event when it stops
/// counting as a call, so the probe's `callInFlight` schedules one more attempt for then.
public actor IdleOwnerRestart {
    public enum Outcome: Equatable, Sendable {
        /// No restart yet: the owner was busy.
        case waiting
        /// The owner accepted the restart.
        case started
        /// The owner refused the restart; it is not tried again.
        case refused
    }

    public private(set) var outcome: Outcome = .waiting
    private let probe: OwnerIdleProbe
    private let restart: @Sendable () async -> Bool
    /// A probe runs now. One attempt that came meanwhile waits here and probes next (its event
    /// may have come after the running probe read the owner); later ones are covered by it.
    private var probing = false
    private var queued: [CheckedContinuation<Void, Never>] = []
    /// One attempt when the youngest client without a kind stops counting as a call. One-shot;
    /// cancelled once the outcome is decided, and with this actor (`DemandTimer.deinit`).
    private let callEnds = DemandTimer(owner: "idle-owner-restart.call")

    public init(probe: OwnerIdleProbe, restart: @escaping @Sendable () async -> Bool) {
        self.probe = probe
        self.restart = restart
    }

    /// Restarts the owner if it is idle now; the outcome. Each call runs at most one probe: one
    /// that comes during a running probe runs its own probe right after it (the event that asked
    /// may have come after the running probe read the owner); a call when one already waits
    /// returns at once, because that waiting probe reads the owner after this event too.
    @discardableResult
    public func attempt() async -> Outcome {
        guard outcome == .waiting else { return outcome }
        if probing {
            guard queued.isEmpty else { return outcome }
            // The running probe hands over to this one when it ends (`probing` stays true).
            await withCheckedContinuation { queued.append($0) }
            guard outcome == .waiting else {
                finishProbe()
                return outcome
            }
        } else {
            probing = true
        }
        switch await probe.reading() {
        case .idle:
            outcome = await restart() ? .started : .refused
            callEnds.cancel()
        case .callInFlight(let seconds):
            // Whole seconds on the wire: one more makes sure the client counts as standing by then.
            callEnds.scheduleIfIdle(after: .seconds(seconds + 1)) { [weak self] in _ = await self?.attempt() }
        case .busy:
            break
        }
        finishProbe()
        return outcome
    }

    /// Ends this probe: hands over to the waiting attempt, if any.
    private func finishProbe() {
        if queued.isEmpty {
            probing = false
        } else {
            queued.removeFirst().resume()
        }
    }

    /// An event of the owner's connection: tries again when it can end the owner's
    /// business; the outcome.
    @discardableResult
    public func note(_ event: DaemonEvent) async -> Outcome {
        guard outcome == .waiting, Self.mayEndBusy(event) else { return outcome }
        return await attempt()
    }

    /// Whether `event` can make a busy owner idle.
    public static func mayEndBusy(_ event: DaemonEvent) -> Bool {
        switch event {
        case .client(let name, _):
            return name == "client-detached" || name == "client-changed" || name == "client-list-invalidated"
        case .conversationTyping:
            return true
        default:
            return false
        }
    }
}
