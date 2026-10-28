import CmuxNextDaemon

/// One home session owns personal order across all windows. Keep the UI's
/// edits immediate, but plan each write after the previous write is applied.
@MainActor
public final class PersonalPlacementQueue {
    private var tail: Task<Bool, Never>?
    private var serial = 0

    public init() {}

    public func enqueue(on home: DaemonService, failed: @escaping @MainActor () -> Void,
                 operation: @escaping @MainActor () async -> Bool) {
        let previous = tail
        serial += 1
        let own = serial
        // Open before the task waits: a CLI action is not done while queued.
        let ticket = home.openTicket("queued personal placement")
        // task-owner: one queued placement; releases its ticket on every outcome
        tail = Task { [weak self] in
            let prior = await previous?.value ?? true
            let ok = prior && !Task.isCancelled ? await operation() : false
            if !ok { failed() }
            await home.closeTicket(ticket, label: "queued personal placement", error: ok ? nil : DaemonError.notConnected)
            if self?.serial == own { self?.tail = nil }
            return ok
        }
    }
}
