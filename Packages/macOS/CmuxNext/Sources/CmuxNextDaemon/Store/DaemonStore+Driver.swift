import Foundation
import Synchronization

/// Off-main event buffer. The pump appends; the main actor takes whole
/// batches. At most one frame is requested per non-empty buffer.
final class EventInbox: Sendable {
    private struct State {
        var events: [DaemonEventEnvelope] = []
        var framePending = false
    }

    private let state = Mutex(State())

    /// Returns true when the caller must schedule a frame.
    func append(_ envelope: DaemonEventEnvelope) -> Bool {
        state.withLock { state in
            state.events.append(envelope)
            guard !state.framePending else { return false }
            state.framePending = true
            return true
        }
    }

    /// Takes everything buffered and clears the pending-frame flag.
    func take() -> [DaemonEventEnvelope] {
        state.withLock { state in
            state.framePending = false
            defer { state.events.removeAll(keepingCapacity: true) }
            return state.events
        }
    }

    /// Keeps new events from scheduling frames (during a resync).
    func hold() {
        state.withLock { $0.framePending = true }
    }
}

struct StoreDriver {
    let connection: DaemonConnection
    let inbox: EventInbox
    let scheduler: any FrameScheduler
}

extension DaemonStore {
    /// Mirrors the daemon until the connection closes. The event stream is
    /// consumed off the main actor; batches reach the main actor at most once
    /// per frame. A batch that invalidates the tree triggers one snapshot,
    /// fetched and decoded off the main actor; events it supersedes (by
    /// sequence barrier) are dropped. No polling and no timers.
    public func run(connection: DaemonConnection, scheduler: any FrameScheduler = NextTurnFrameScheduler()) async {
        let driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: scheduler)
        self.driver = driver
        let pump = Task.detached { [weak self] () -> String? in
            do {
                for try await envelope in connection.events where driver.inbox.append(envelope) {
                    driver.scheduler.scheduleFrame { self?.drain() }
                }
                return nil
            } catch {
                return String(describing: error)
            }
        }
        let failure = await pump.value
        drain()
        if let failure { markFailed(failure) }
        self.driver = nil
    }

    /// Applies everything buffered as one batch.
    func drain() {
        guard let driver, !isResyncing else { return }
        let batch = driver.inbox.take()
        guard !batch.isEmpty else { return }
        let connected = batch.contains { if case .connected = $0.event { true } else { false } }
        if apply(batch: batch) == .resync {
            resync(seedAgents: connected)
        }
    }

    /// Fetches and applies a snapshot, then flushes events held meanwhile.
    func resync(seedAgents: Bool = false) {
        guard let driver, !isResyncing else { return }
        isResyncing = true
        driver.inbox.hold()
        Task { @MainActor in
            do {
                let (tree, barrier) = try await driver.connection.snapshot()
                apply(snapshot: tree)
                snapshotBarrier = max(snapshotBarrier, barrier)
                if seedAgents { apply(agents: try await driver.connection.agents()) }
            } catch {
                logger.error("resync failed: \(String(describing: error), privacy: .public)")
            }
            isResyncing = false
            drain()
        }
    }
}
