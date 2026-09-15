import Foundation

/// Owns every loopback port forward the app has open, keyed by Cloud machine
/// and VM port, so one (machine, port) maps to one stable local port for as
/// long as the machine is registered. Forwards close when the machine leaves
/// the fleet, on sign-out, and with the process.
actor CloudHubPortForwarder {
    struct Key: Hashable, Sendable {
        let machineID: String
        let port: Int
    }

    /// Builds one forward. The forwarder takes its two dependencies through
    /// `init`: the hub dialer and this builder, whose default binds the app's
    /// loopback ``CloudLoopbackPortForward``. A loopback listener on an
    /// ephemeral port cannot be made to fail for real, so a failed bind is
    /// covered by substituting the builder rather than by a debug hook.
    typealias ForwardFactory = @Sendable (CloudPortForwardTarget, any CloudHubDialing) throws -> CloudLoopbackPortForward

    private let dialer: any CloudHubDialing
    private let makeForward: ForwardFactory
    private var forwards: [Key: CloudLoopbackPortForward] = [:]
    private struct StartEntry {
        let id: UUID
        let task: Task<CloudLoopbackPortForward, any Error>
        var waiters: Set<UUID>
    }
    private var starting: [Key: StartEntry] = [:]

    init(
        dialer: any CloudHubDialing,
        makeForward: @escaping ForwardFactory = { try CloudLoopbackPortForward(target: $0, dialer: $1) }
    ) {
        self.dialer = dialer
        self.makeForward = makeForward
    }

    /// The forward for `target.port` on `machineID`, started on first use.
    /// Concurrent first uses share one start and the same bookkeeping; a
    /// changed private address retargets the existing listener so open panes
    /// keep their URL; a listener that died is torn down before it is replaced.
    func forward(machineID: String, to target: CloudPortForwardTarget) async throws -> CloudLoopbackPortForward {
        let key = Key(machineID: machineID, port: target.port)
        while true {
            if let existing = forwards[key] {
                let listening = await existing.isListening
                guard forwards[key] === existing else { continue }
                if listening {
                    await Self.retargetIfNeeded(existing, to: target)
                    guard forwards[key] === existing else { continue }
                    return existing
                }
                forwards[key] = nil
                await existing.stop()
                guard forwards[key] == nil else { continue }
            }

            let entry: StartEntry
            let waiterID = UUID()
            if var inFlight = starting[key] {
                inFlight.waiters.insert(waiterID)
                starting[key] = inFlight
                entry = inFlight
            } else {
                let dialer = self.dialer
                let makeForward = self.makeForward
                let task = Task { () throws -> CloudLoopbackPortForward in
                    let forward = try makeForward(target, dialer)
                    do {
                        try await forward.start()
                        try Task.checkCancellation()
                        return forward
                    } catch {
                        await forward.stop()
                        throw error
                    }
                }
                let newEntry = StartEntry(id: UUID(), task: task, waiters: [waiterID])
                starting[key] = newEntry
                entry = newEntry
            }

            // Only the bind itself is caught here: a failed or cancelled bind
            // must drop its entry so the next open binds fresh. Everything
            // after a successful bind is bookkeeping and never clears the
            // entry another waiter may still own.
            let forward: CloudLoopbackPortForward
            do {
                forward = try await withTaskCancellationHandler {
                    try await entry.task.value
                } onCancel: {
                    Task { await self.cancelStartWaiter(key: key, entryID: entry.id, waiterID: waiterID) }
                }
            } catch {
                if starting[key]?.id == entry.id {
                    starting[key] = nil
                }
                throw error
            }
            guard finishStartWaiter(key: key, entryID: entry.id, waiterID: waiterID) else {
                if let stored = forwards[key], stored === forward {
                    await Self.retargetIfNeeded(stored, to: target)
                    return stored
                }
                if let current = starting[key], current.id == entry.id {
                    // This waiter was cancelled; another waiter on the same
                    // start still owns the bookkeeping and will store it.
                    throw CancellationError()
                }
                // Nobody else will keep this listener.
                await forward.stop()
                throw CancellationError()
            }
            // A waiter cancelled after the bind finished still completes the
            // bookkeeping: other waiters may share this forward, and the
            // caller simply ignores the result.
            guard let current = starting[key], current.id == entry.id else {
                await forward.stop()
                throw CancellationError()
            }
            starting[key] = nil
            forwards[key] = forward
            await Self.retargetIfNeeded(forward, to: target)
            guard forwards[key] === forward else {
                await forward.stop()
                throw CancellationError()
            }
            return forward
        }
    }

    private func finishStartWaiter(key: Key, entryID: UUID, waiterID: UUID) -> Bool {
        guard var entry = starting[key], entry.id == entryID else { return false }
        guard entry.waiters.remove(waiterID) != nil else { return false }
        starting[key] = entry
        return true
    }

    private func cancelStartWaiter(key: Key, entryID: UUID, waiterID: UUID) {
        guard var entry = starting[key], entry.id == entryID else { return }
        guard entry.waiters.remove(waiterID) != nil else { return }
        if entry.waiters.isEmpty {
            starting[key] = nil
            entry.task.cancel()
        } else {
            starting[key] = entry
        }
    }

    private static func retargetIfNeeded(_ forward: CloudLoopbackPortForward, to target: CloudPortForwardTarget) async {
        if await forward.target != target {
            await forward.retarget(target)
        }
    }

    /// The local port already forwarding to `port` on `machineID`, if any.
    func localPort(machineID: String, port: Int) async -> UInt16? {
        await forwards[Key(machineID: machineID, port: port)]?.localPort
    }

    var count: Int { forwards.count }

    func close(machineID: String, port: Int) async {
        await close(Key(machineID: machineID, port: port))
    }

    /// Closes every forward on a machine (it left the fleet or was deleted).
    func close(machineID: String) async {
        await close(machineIDs: [machineID])
    }

    /// One pass over the tables for a whole batch of machines that left the
    /// fleet, so a refresh that drops many at once pays one actor hop.
    func close(machineIDs: Set<String>) async {
        guard !machineIDs.isEmpty else { return }
        for key in Set(forwards.keys).union(starting.keys) where machineIDs.contains(key.machineID) {
            await close(key)
        }
    }

    func closeAll() async {
        for key in Set(forwards.keys).union(starting.keys) {
            await close(key)
        }
    }

    private func close(_ key: Key) async {
        if let entry = starting.removeValue(forKey: key) {
            entry.task.cancel()
        }
        if let forward = forwards.removeValue(forKey: key) {
            await forward.stop()
        }
    }
}
