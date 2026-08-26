import Dispatch
import Foundation

/// Watches exact PID generations and reports process exit back on the main
/// actor. Callers still compare the generation before mutating owner state.
@MainActor
final class AgentProcessExitMonitor {
    private var observationsByKey: [String: AgentProcessExitObservation] = [:]
    private let livenessProbe: (AgentPIDProcessIdentity) -> AgentTurnProcessLiveness

    init(
        livenessProbe: @escaping (AgentPIDProcessIdentity) -> AgentTurnProcessLiveness =
            AgentProcessExitMonitor.defaultLivenessProbe
    ) {
        self.livenessProbe = livenessProbe
    }

    deinit {
        // This app-owned monitor is created and released on the main actor.
        // `isolated deinit` cannot be compiled by Xcode 16.4, which cmux uses
        // for Intel macOS 14 verification, so assert that owner invariant while
        // keeping teardown synchronous on every supported toolchain.
        MainActor.assumeIsolated {
            for observation in observationsByKey.values {
                observation.source.cancel()
            }
        }
    }

    func observe(
        key: String,
        generation: AgentPIDProcessIdentity,
        onExit: @escaping @MainActor (String, AgentPIDProcessIdentity) -> Void
    ) {
        if observationsByKey[key]?.generation == generation {
            return
        }
        cancel(key: key)

        // DispatchSource is the Darwin process-exit primitive; its callback is
        // only a bridge into the MainActor-owned reconciliation state.
        let source = DispatchSource.makeProcessSource(
            identifier: generation.pid,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        observationsByKey[key] = AgentProcessExitObservation(
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
        if !generationIsStillLive(generation) {
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

    private func generationIsStillLive(
        _ generation: AgentPIDProcessIdentity
    ) -> Bool {
        // Only exact live evidence keeps a watcher. Unknown identity is
        // retired conservatively so an unreadable, already-gone PID cannot
        // strand lifecycle state indefinitely.
        livenessProbe(generation) == .live
    }

    private nonisolated static func defaultLivenessProbe(
        _ generation: AgentPIDProcessIdentity
    ) -> AgentTurnProcessLiveness {
        AgentTurnProcessLiveness.observe(
            pid: Int(generation.pid),
            expectedStartSeconds: generation.startSeconds,
            expectedStartMicroseconds: generation.startMicroseconds
        )
    }
}
