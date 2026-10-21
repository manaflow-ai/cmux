import CmuxNextCompat
import CmuxNextDaemon
import Foundation

extension AgentCLIUpdateActions {
    /// Events invalidate a projection; only a bounded read of the retained receipt supplies an outcome.
    func follow(_ intent: Intent) {
        guard intent.following == nil, !intent.receipts.isEmpty, intent.route.isCurrent(),
              intent.inputs.contains(where: { !settled.contains($0.key) }), let changes = intent.route.changes else { return }
        let route = intent.route
        let events = changes() // Subscribe before the first read so an exit during it stays queued.
        // task-owner: the intent; cancellation retires observation, never the owner's process.
        intent.following = Task { [weak self, weak intent] in
            if let self, let intent { await self.observe(intent, route: route) }
            for await _ in events {
                guard !Task.isCancelled, route.isCurrent(), let self, let intent else { break }
                await self.observe(intent, route: route)
            }
        }
    }

    func observe(_ intent: Intent, route: Route) async {
        for receipt in intent.receipts {
            guard !Task.isCancelled, route.isCurrent() else { break }
            let key = intent.inputs.first { $0.family == receipt.cli }?.key
            if let key, settled.contains(key) { continue }
            do {
                let status = try await route.observe(receipt)
                guard !Task.isCancelled, route.isCurrent(), status.terminalID == receipt.path.terminalID,
                      status.revision >= (intent.outcomeRevisions[status.terminalID] ?? 0),
                      key.map({ !settled.contains($0) }) ?? true,
                      let index = intent.jobs.firstIndex(where: { $0["terminal"]?.stringValue == status.terminalID.rawValue }),
                      var job = intent.jobs[index].objectValue else { continue }
                intent.outcomeRevisions[status.terminalID] = status.revision
                // An end observation settles the job even when it has no process result.
                job["state"] = .string(status.state.rawValue)
                switch status.outcome {
                case .exit(let code): job["exit_code"] = .number(Double(code))
                case .signal(let number): job["signal"] = .number(Double(number))
                case .unknown: job["outcome"] = "unknown"
                case nil: break
                }
                intent.jobs[index] = .object(job)
                // Any exit, even one whose outcome is unknown, ends the process: it settles.
                if status.state == .exited, let key { await settle(key, in: nil) }
                if intent.inputs.allSatisfy({ settled.contains($0.key) }) {
                    // A completed batch no longer subscribes to unrelated terminal changes.
                    intent.following?.cancel()
                }
            } catch where Self.terminalGone(error) {
                // The person closed the kept tab, so the job settles. Rust answers terminal.closed before
                // it queues the runtime signal, so the updater may still be dying in its close grace.
                guard route.isCurrent(), let key, !settled.contains(key),
                      let index = intent.jobs.firstIndex(where: { $0["terminal"]?.stringValue == receipt.path.terminalID.rawValue }),
                      var job = intent.jobs[index].objectValue else { continue }
                job["state"] = "exited"; intent.jobs[index] = .object(job)
                await settle(key, in: nil)
                if intent.inputs.allSatisfy({ settled.contains($0.key) }) { intent.following?.cancel() }
            } catch {
                // Keep the original receipt; a failed observation establishes no completion.
            }
        }
    }

    /// Coalesce changes only from the admitted control connection. A replacement
    /// connection, withdrawn policy or detached owner ends this subscription.
    static func terminalChanges(sideEvents: DaemonSideEvents, stamp: DaemonControlStamp,
                                current: @escaping @MainActor () -> Bool) -> AsyncStream<Void> {
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = sideEvents.subscribeEnvelopes { envelope in
            guard current(), sideEvents.controlStamp == stamp else { continuation.finish(); return }
            guard envelope.sourceID == stamp.sourceID, envelope.connectionSerial == stamp.serial else { return }
            if case .terminalRegistryChanged = envelope.event { continuation.yield() }
        }
        // task-owner: the stream; its termination cancels this connection/policy observer.
        let lifecycle = Task {
            for await admitted in ObservationStream({ current() && sideEvents.controlStamp == stamp }) {
                guard admitted else { continuation.finish(); return }
            }
        }
        continuation.onTermination = { _ in
            lifecycle.cancel()
            // The AsyncStream termination callback may arrive off the main actor.
            Task { @MainActor in sideEvents.unsubscribe(token) }
        }
        return events
    }
}
