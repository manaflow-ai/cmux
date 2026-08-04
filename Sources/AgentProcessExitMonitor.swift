import Darwin
import Dispatch
import Foundation

/// Watches exact PID generations and reports process exit back on the main
/// actor. Callers still compare the generation before mutating owner state.
@MainActor
final class AgentProcessExitMonitor {
    private struct Observation {
        let generation: AgentPIDProcessIdentity
        let source: DispatchSourceProcess
        let onExit: @MainActor (String, AgentPIDProcessIdentity) -> Void
    }

    private var observationsByKey: [String: Observation] = [:]

    deinit {
        // Workspace and dock teardown cancel eagerly; this closes the final
        // ownership edge if an owner is released before its normal teardown.
        for observation in observationsByKey.values {
            observation.source.cancel()
        }
    }

    func observe(
        key: String,
        generation: AgentPIDProcessIdentity,
        onExit: @escaping @MainActor (String, AgentPIDProcessIdentity) -> Void
    ) {
        cancel(key: key)

        // DispatchSource is the Darwin process-exit primitive; its callback is
        // only a bridge into the MainActor-owned reconciliation state.
        let source = DispatchSource.makeProcessSource(
            identifier: generation.pid,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        observationsByKey[key] = Observation(
            generation: generation,
            source: source,
            onExit: onExit
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.deliverExit(key: key, generation: generation)
            }
        }
        source.resume()
        if !Self.generationIsStillLive(generation) {
            deliverExit(key: key, generation: generation)
        }
    }

    func cancel(key: String) {
        observationsByKey.removeValue(forKey: key)?.source.cancel()
    }

    func cancelAll() {
        let observations = Array(observationsByKey.values)
        observationsByKey.removeAll()
        for observation in observations {
            observation.source.cancel()
        }
    }

    private func deliverExit(
        key: String,
        generation: AgentPIDProcessIdentity
    ) {
        guard let observation = observationsByKey[key],
              observation.generation == generation else {
            return
        }
        observationsByKey.removeValue(forKey: key)
        observation.source.cancel()
        observation.onExit(key, generation)
    }

    private static func generationIsStillLive(
        _ generation: AgentPIDProcessIdentity
    ) -> Bool {
        if let current = AgentPIDProcessIdentity(pid: generation.pid) {
            return current == generation
        }
        // A process can be live while proc_pidinfo is unreadable. Treat that
        // ambiguous case as live so the exit monitor never invents an exit;
        // AgentTurnProcessLiveness.observe likewise reports it as `.unknown`
        // rather than `.exited`.
        return Darwin.kill(generation.pid, 0) == 0 || errno == EPERM
    }
}
