import Foundation

actor AuthPhaseTimeoutRegistry {
    private var activePhases: [String: Set<UUID>] = [:]
    private var timedOutPhases: [String: UUID] = [:]

    func canBegin(_ phase: AuthPhase) -> Bool {
        timedOutPhases[phase.rawValue] == nil
    }

    func begin(_ phase: AuthPhase, id: UUID) -> Bool {
        let key = phase.rawValue
        guard timedOutPhases[key] == nil else { return false }
        activePhases[key, default: []].insert(id)
        return true
    }

    func markTimedOut(_ phase: AuthPhase, id: UUID) {
        let key = phase.rawValue
        guard activePhases[key]?.contains(id) == true else { return }
        timedOutPhases[key] = id
    }

    func end(_ phase: AuthPhase, id: UUID) {
        let key = phase.rawValue
        activePhases[key]?.remove(id)
        if activePhases[key]?.isEmpty == true {
            activePhases[key] = nil
        }
        guard timedOutPhases[key] == id else { return }
        timedOutPhases[key] = nil
    }

    func clear(_ phases: [AuthPhase]) {
        for phase in phases {
            activePhases[phase.rawValue] = nil
            timedOutPhases[phase.rawValue] = nil
        }
    }
}
