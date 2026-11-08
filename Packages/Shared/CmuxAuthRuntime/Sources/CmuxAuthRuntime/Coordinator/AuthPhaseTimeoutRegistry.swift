import Foundation

actor AuthPhaseTimeoutRegistry {
    private let timedOutResetNanoseconds: UInt64
    private var activePhases: [String: Set<UUID>] = [:]
    private var timedOutPhases: [String: AuthPhaseTimedOutState] = [:]

    init(timedOutResetNanoseconds: UInt64 = 30_000_000_000) {
        self.timedOutResetNanoseconds = timedOutResetNanoseconds
    }

    func canBegin(_ phase: AuthPhase) -> Bool {
        let key = phase.rawValue
        expireTimedOutPhaseIfNeeded(key)
        return timedOutPhases[key] == nil && activePhases[key]?.isEmpty != false
    }

    func begin(_ phase: AuthPhase, id: UUID) -> Bool {
        let key = phase.rawValue
        expireTimedOutPhaseIfNeeded(key)
        guard timedOutPhases[key] == nil, activePhases[key]?.isEmpty != false else {
            return false
        }
        activePhases[key, default: []].insert(id)
        return true
    }

    func markTimedOut(_ phase: AuthPhase, id: UUID) {
        let key = phase.rawValue
        guard activePhases[key]?.contains(id) == true else { return }
        timedOutPhases[key] = AuthPhaseTimedOutState(
            id: id,
            expiresAt: DispatchTime.now().uptimeNanoseconds &+ timedOutResetNanoseconds
        )
    }

    func end(_ phase: AuthPhase, id: UUID) {
        let key = phase.rawValue
        activePhases[key]?.remove(id)
        if activePhases[key]?.isEmpty == true {
            activePhases[key] = nil
        }
        guard timedOutPhases[key]?.id == id else { return }
        timedOutPhases[key] = nil
    }

    func clear(_ phases: [AuthPhase]) {
        for phase in phases {
            activePhases[phase.rawValue] = nil
            timedOutPhases[phase.rawValue] = nil
        }
    }

    private func expireTimedOutPhaseIfNeeded(_ key: String) {
        guard let timedOut = timedOutPhases[key] else { return }
        guard DispatchTime.now().uptimeNanoseconds >= timedOut.expiresAt else { return }
        activePhases[key] = nil
        timedOutPhases[key] = nil
    }

    /// Supersede every parked timed-out phase for an explicit interactive
    /// attempt. A timed-out phase's operation was already cancelled at its
    /// deadline and the sign-in write chokepoint drops a cancelled flow's
    /// token writes, so the damper's only remaining job is suppressing
    /// AUTOMATIC retry hammering; an explicit user action (a pairing attempt,
    /// a tapped retry) is entitled to reclaim the phase immediately. Only the
    /// timed-out operation's slot is released: a live, untimed-out operation
    /// keeps refusing concurrent begins exactly as before.
    func supersedeTimedOutPhases() {
        for (key, state) in timedOutPhases {
            activePhases[key]?.remove(state.id)
            if activePhases[key]?.isEmpty == true {
                activePhases[key] = nil
            }
        }
        timedOutPhases.removeAll()
    }
}
