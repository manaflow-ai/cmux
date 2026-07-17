import Foundation

/// Serializes setup and teardown for each detected-agent terminal surface.
///
/// A replacement setup waits for any prior teardown. Repeated teardown calls
/// are ignored while cleanup is already in flight.
@MainActor
final class AgentTerminalSurfaceTaskSequencer {
    typealias Operation = @MainActor @Sendable () async -> Void

    private enum Phase {
        case active(token: UUID, task: Task<Void, Never>)
        case stopping(token: UUID, task: Task<Void, Never>)

        var task: Task<Void, Never> {
            switch self {
            case .active(_, let task), .stopping(_, let task): task
            }
        }
    }

    private var phases: [UUID: Phase] = [:]

    deinit {
        phases.values.forEach { $0.task.cancel() }
    }

    func install(surfaceID: UUID, operation: @escaping Operation) {
        let predecessor: Task<Void, Never>?
        if let phase = phases[surfaceID] {
            predecessor = phase.task
            if case .active = phase { predecessor?.cancel() }
        } else {
            predecessor = nil
        }

        let token = UUID()
        let task = Task { @MainActor in
            _ = await predecessor?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        phases[surfaceID] = .active(token: token, task: task)
    }

    func drop(surfaceID: UUID, operation: @escaping Operation) {
        guard case .active(_, let registrationTask) = phases[surfaceID] else { return }
        registrationTask.cancel()

        let token = UUID()
        let task = Task { @MainActor [weak self] in
            _ = await registrationTask.value
            await operation()
            guard let self,
                  let phase = self.phases[surfaceID],
                  case .stopping(let currentToken, _) = phase,
                  currentToken == token else { return }
            self.phases.removeValue(forKey: surfaceID)
        }
        phases[surfaceID] = .stopping(token: token, task: task)
    }
}
