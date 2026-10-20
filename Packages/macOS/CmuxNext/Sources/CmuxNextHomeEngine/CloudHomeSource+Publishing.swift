import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: Publishing

    func publish(_ event: HomeEvent) {
        publish { _ in event }
    }

    /// Builds and yields one event under the lock, so revisions reach every
    /// subscriber in the order they were assigned.
    func publish(generation: UInt64? = nil, _ build: (inout CloudHomeState) -> HomeEvent?) {
        state.withLock { state in
            if let generation, state.generation != generation { return }
            guard let event = build(&state) else { return }
            switch event {
            case .connection: state.lastEvent = [event]
            case .inbox: state.lastEvent = state.lastEvent.filter { if case .connection = $0 { true } else { false } } + [event]
            default: break
            }
            for continuation in state.continuations.values { continuation.yield(event) }
        }
    }
}
