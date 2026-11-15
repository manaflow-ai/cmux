import CmuxRemoteWire
import Darwin
import Foundation
import os

/// Admission and reaping at the synchronous posix_spawn/waitpid boundary.
/// The lock is a short callback compare-and-set; waiting is an AsyncStream, never a main-thread join.
final class RemoteChildLifetime: Sendable {
    private struct State {
        var accepting = true
        var permanentlyClosed = false
        var starting = 0
        var children: [UUID: ProcessStamp?] = [:]
        var listeners: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var accepting: Bool { state.withLock { $0.accepting } }

    func spawn(executable: String, arguments: [String], environment: [String: String], logPath: String) throws -> ChildProcess {
        guard state.withLock({ value in
            guard value.accepting else { return false }
            value.starting += 1
            return true
        }) else { throw CocoaError(.userCancelled) }
        do {
            let child = try ChildProcess.spawn(executable: executable, arguments: arguments, environment: environment, logPath: logPath)
            let stop = state.withLock { value in
                value.starting -= 1
                value.children[child.lifetimeID] = .some(ProcessStamp.of(child.pid))
                return !value.accepting
            }
            // A spawn admitted before the freeze belongs to this host and must also terminate.
            if stop { stopOwnedChildren([child]) }
            return child
        } catch {
            state.withLock { $0.starting -= 1 }
            changed()
            throw error
        }
    }

    /// Called only by the child's sole waitpid owner, after a successful reap.
    func reaped(_ child: ChildProcess) {
        state.withLock { _ = $0.children.removeValue(forKey: child.lifetimeID) }
        changed()
    }

    /// Reaps a tracked child without blocking while holding the signal gate.
    /// The same gate serializes this operation with every owned signal, so a PID
    /// cannot be reused between the identity check and `kill`.
    func waitForExit(_ child: ChildProcess) -> Int32 {
        var status: Int32 = 0
        while true {
            let result = state.withLock { waitpid(child.pid, &status, WNOHANG) }
            if result == child.pid { return status }
            if result < 0, errno != EINTR { return -1 }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Starts the gated nonblocking reaper for one tracked child.
    func watch(_ child: ChildProcess, name: String, onExit: @escaping @Sendable (Int32) -> Void) {
        let thread = Thread { [self] in
            onExit(waitForExit(child))
        }
        thread.name = name
        thread.start()
    }

    /// Permanently closes admission for this host instance. Existing children are stopped by their owners.
    func freeze() { state.withLock { $0.accepting = false; $0.permanentlyClosed = true } }

    /// Prepare claims the spawn boundary only while no child or in-flight spawn exists.
    func claimIdle() -> Bool {
        state.withLock { value in
            guard value.accepting, value.starting == 0, value.children.isEmpty else { return false }
            value.accepting = false
            return true
        }
    }

    func reopenAfterPrepare() { state.withLock { if !$0.permanentlyClosed { $0.accepting = true } } }

    func stopOwnedChildren() {
        state.withLock { value in
            for stored in value.children.values {
                guard let stamp = stored, ProcessStamp.of(stamp.pid) == stamp else { continue }
                _ = kill(stamp.pid, SIGTERM)
            }
        }
    }

    /// Signals only the supplied tracked children while holding the reap gate.
    /// A stale ProcessStamp is ignored, so a reused PID is never targeted.
    func stopOwnedChildren(_ children: [ChildProcess]) {
        state.withLock { value in
            for child in children {
                guard let stored = value.children[child.lifetimeID], let stamp = stored,
                      ProcessStamp.of(stamp.pid) == stamp else { continue }
                _ = kill(stamp.pid, SIGTERM)
            }
        }
    }

    func waitUntilEmpty(timeout: Duration) async -> Bool {
        let id = UUID()
        let pair = AsyncStream<Bool>.makeStream()
        state.withLock { value in
            value.listeners[id] = pair.continuation
            pair.continuation.yield(value.starting == 0 && value.children.isEmpty)
        }
        defer {
            state.withLock { _ = $0.listeners.removeValue(forKey: id) }
            pair.continuation.finish()
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await empty in pair.stream { if empty { return true } }
                return false
            }
            group.addTask {
                // A genuine shutdown deadline, not a polling delay.
                try? await ContinuousClock().sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func changed() {
        state.withLock { value in
            let empty = value.starting == 0 && value.children.isEmpty
            for listener in value.listeners.values { listener.yield(empty) }
        }
    }
}
