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
        var children: [pid_t: ProcessStamp?] = [:]
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
                value.children[child.pid] = .some(ProcessStamp.of(child.pid))
                return !value.accepting
            }
            // A spawn admitted before the freeze belongs to this host and must also terminate.
            if stop { kill(child.pid, SIGTERM) }
            return child
        } catch {
            state.withLock { $0.starting -= 1 }
            changed()
            throw error
        }
    }

    /// Called only by the child's sole waitpid owner, after a successful reap.
    func reaped(_ pid: pid_t) {
        state.withLock { _ = $0.children.removeValue(forKey: pid) }
        changed()
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
        let stamps = state.withLock { Array($0.children.values) }
        for stamp in stamps {
            if let stamp, stamp.isAlive { kill(stamp.pid, SIGTERM) }
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
