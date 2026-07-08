import Foundation
import os

/// Executes OWL runtime calls on the single pinned thread the runtime requires.
///
/// `owl_fresh_mojo_global_init` installs Chromium's `SingleThreadTaskExecutor`
/// on the calling thread; every later runtime call must run on that thread,
/// and events are only delivered while it pumps `owl_fresh_mojo_poll_events`.
/// An actor cannot pin an OS thread, so commands cross to the pinned thread
/// through a lock-guarded buffer it drains between polls. The thread runs for
/// the rest of the process because Chromium cannot be unloaded.
// All mutable state lives inside the OSAllocatedUnfairLock below.
final class ChromiumRuntimeExecutor: @unchecked Sendable {
    typealias Command = @Sendable (Result<OwlRuntimeLibrary, any Error>) -> Void

    private enum Phase {
        case idle
        case starting
        case running
        case failed
    }

    private struct State {
        var phase: Phase = .idle
        var commands: [Command] = []
    }

    // Lock carve-out: an actor cannot provide the thread affinity the runtime
    // demands; critical sections only append to or swap the command buffer.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Poll timeout bounds command latency: enqueued work waits at most this long.
    private static let pollTimeoutMilliseconds: UInt32 = 8

    /// Starts the pinned runtime thread, running `bootstrap` on it first.
    ///
    /// Returns once bootstrap succeeds; commands enqueued before or during
    /// startup run right after it. A failed bootstrap fails pending commands
    /// and leaves the executor permanently unavailable.
    func start(_ bootstrap: @escaping @Sendable () throws -> OwlRuntimeLibrary) async throws {
        enum StartAction {
            case bootstrap
            case alreadyAvailable
            case unavailable
        }
        let action = state.withLock { st -> StartAction in
            switch st.phase {
            case .idle:
                st.phase = .starting
                return .bootstrap
            case .starting, .running:
                return .alreadyAvailable
            case .failed:
                return .unavailable
            }
        }
        switch action {
        case .alreadyAvailable:
            return
        case .unavailable:
            throw ChromiumRuntimeError.runtimeUnavailable
        case .bootstrap:
            break
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let state = self.state
            let thread = Thread {
                let library: OwlRuntimeLibrary
                do {
                    library = try bootstrap()
                } catch {
                    let pending = state.withLock { st -> [Command] in
                        st.phase = .failed
                        let commands = st.commands
                        st.commands = []
                        return commands
                    }
                    for command in pending {
                        command(.failure(error))
                    }
                    continuation.resume(throwing: error)
                    return
                }
                state.withLock { $0.phase = .running }
                continuation.resume()
                while true {
                    let batch = state.withLock { st -> [Command] in
                        let commands = st.commands
                        st.commands = []
                        return commands
                    }
                    for command in batch {
                        command(.success(library))
                    }
                    library.pollEvents(Self.pollTimeoutMilliseconds)
                }
            }
            thread.name = "com.cmux.chromium-runtime"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    /// Runs `body` on the runtime thread and returns its result.
    func run<T: Sendable>(_ body: @escaping @Sendable (OwlRuntimeLibrary) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let accepted = state.withLock { st -> Bool in
                switch st.phase {
                case .idle, .failed:
                    return false
                case .starting, .running:
                    st.commands.append { result in
                        switch result {
                        case .success(let library):
                            continuation.resume(with: Result { try body(library) })
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                    return true
                }
            }
            if !accepted {
                continuation.resume(throwing: ChromiumRuntimeError.runtimeUnavailable)
            }
        }
    }

    /// Enqueues fire-and-forget work on the runtime thread (input, resize, teardown).
    func post(_ body: @escaping @Sendable (OwlRuntimeLibrary) -> Void) {
        state.withLock { st in
            guard st.phase == .starting || st.phase == .running else { return }
            st.commands.append { result in
                if case .success(let library) = result {
                    body(library)
                }
            }
        }
    }
}
