import Foundation

extension CMUXCLI {
    internal func openSSHLocalCommandValue(shellScript: String?) -> String? {
        guard let shellScript else { return nil }
        let trimmed = shellScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return openSSHCommandOptionValue(posixShellCommand(trimmed))
    }

    internal func openSSHRemoteCommandValue(shellScript: String) -> String {
        openSSHCommandOptionValue(posixShellCommand(shellScript))
    }

    internal func posixShellCommand(_ shellScript: String) -> String {
        "/bin/sh -c " + shellQuote(shellScript)
    }

    internal func openSSHCommandOptionValue(_ command: String) -> String {
        command.replacingOccurrences(of: "%", with: "%%")
    }

    /// Joins self-delimiting POSIX shell snippets with one space; this is not a general shell combiner.
    internal func combinedLocalShellScript(_ parts: [String?]) -> String? {
        let filtered = parts.compactMap { raw -> String? in
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: " ")
    }
}

/// Coalesces and retries SSH-PTY resize delivery (`workspace.remote.pty_resize`).
///
/// A SIGWINCH burst during a split/divider drag would previously fire one
/// best-effort `try?` send per event, silently dropping any send that raced a
/// stale or blocked remote-session control path. Output kept flowing, so the
/// terminal looked alive while the remote PTY/TUI never received the new size —
/// and only a manual workspace reconnect restored it (issue #6306).
///
/// This coordinator collapses rapid resize events into a single delivery of the
/// newest size and, when a delivery fails, retries the latest size with a
/// bounded backoff instead of dropping it.
///
/// All mutable state is touched only from `noteResize`/`cancel`/`deliver`, which
/// in production all run on a single serial dispatch queue (the signal source's
/// target queue), so no additional locking is required. The `scheduleAfter` and
/// `send` seams are injected so the coalescing/retry state machine can be driven
/// deterministically in tests without real time or a live socket.
final class SSHPTYResizeCoordinator {
    /// Schedules `block` to run after `delay`. Production wires this to the
    /// signal source's serial queue via `asyncAfter`.
    typealias Scheduler = (_ delay: DispatchTimeInterval, _ block: @escaping () -> Void) -> Void

    private let scheduleAfter: Scheduler
    private let send: (_ cols: Int, _ rows: Int) throws -> Void
    private let sizeProvider: () -> (cols: Int, rows: Int)
    private let log: (String) -> Void

    private var pendingSize: (cols: Int, rows: Int)?
    private var lastDeliveredSize: (cols: Int, rows: Int)?
    private var deliveryScheduled = false
    private var retryCount = 0
    private var cancelled = false

    let coalesceDelay: DispatchTimeInterval
    let maxRetries: Int

    init(
        sizeProvider: @escaping () -> (cols: Int, rows: Int),
        send: @escaping (_ cols: Int, _ rows: Int) throws -> Void,
        scheduleAfter: @escaping Scheduler,
        log: @escaping (String) -> Void = { _ in },
        coalesceDelay: DispatchTimeInterval = .milliseconds(20),
        maxRetries: Int = 6
    ) {
        self.sizeProvider = sizeProvider
        self.send = send
        self.scheduleAfter = scheduleAfter
        self.log = log
        self.coalesceDelay = coalesceDelay
        self.maxRetries = maxRetries
    }

    /// Production convenience initializer wiring the send to a `SocketClient`
    /// (serialized by `socketLock`) and scheduling on `queue`.
    convenience init(
        client: SocketClient,
        baseParams: [String: Any],
        socketLock: NSLock,
        queue: DispatchQueue,
        sizeProvider: @escaping () -> (cols: Int, rows: Int),
        log: @escaping (String) -> Void
    ) {
        self.init(
            sizeProvider: sizeProvider,
            send: { cols, rows in
                var params = baseParams
                params["cols"] = cols
                params["rows"] = rows
                socketLock.lock()
                defer { socketLock.unlock() }
                _ = try client.sendV2(method: "workspace.remote.pty_resize", params: params)
            },
            scheduleAfter: { delay, block in
                queue.asyncAfter(deadline: .now() + delay, execute: block)
            },
            log: log
        )
    }

    /// Record a new terminal size and schedule a coalesced delivery.
    /// Invoked from the signal source event handler, which runs on the queue.
    func noteResize() {
        guard !cancelled else { return }
        let size = sizeProvider()
        guard size.cols > 0, size.rows > 0 else { return }
        pendingSize = size
        // A fresh, user-driven resize resets the retry budget so we keep trying
        // to deliver the newest size even after a prior burst gave up.
        retryCount = 0
        scheduleDelivery(after: coalesceDelay)
    }

    /// Stop further delivery. Invoked from the signal source cancel handler,
    /// which also runs on the queue.
    func cancel() {
        cancelled = true
        pendingSize = nil
    }

    private func scheduleDelivery(after delay: DispatchTimeInterval) {
        guard !cancelled, !deliveryScheduled else { return }
        deliveryScheduled = true
        scheduleAfter(delay) { [weak self] in
            self?.deliver()
        }
    }

    private func deliver() {
        deliveryScheduled = false
        guard !cancelled, let size = pendingSize else { return }
        // The newest size already reached the remote; nothing to do.
        if let last = lastDeliveredSize, last == size {
            pendingSize = nil
            retryCount = 0
            return
        }

        let delivered: Bool
        do {
            try send(size.cols, size.rows)
            delivered = true
        } catch {
            delivered = false
            log("ssh-pty resize delivery failed (\(size.cols)x\(size.rows), attempt \(retryCount + 1)): \(error)")
        }

        if delivered {
            lastDeliveredSize = size
            retryCount = 0
            // A newer size may have arrived while the send was in flight.
            if let newest = pendingSize, newest != size {
                scheduleDelivery(after: coalesceDelay)
            } else {
                pendingSize = nil
            }
            return
        }

        // Retry the latest size with a bounded exponential backoff. Keeping
        // pendingSize set means a give-up still recovers on the next SIGWINCH.
        if retryCount < maxRetries {
            retryCount += 1
            let backoffMs = min(1000, 50 * (1 << min(retryCount - 1, 4)))
            scheduleDelivery(after: .milliseconds(backoffMs))
        } else {
            log("ssh-pty resize giving up after \(maxRetries) attempts (\(size.cols)x\(size.rows)); awaiting next resize")
            retryCount = 0
        }
    }
}
