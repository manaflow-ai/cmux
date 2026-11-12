public import Foundation
import CmuxNextCompat

/// Input of a terminal view whose terminal is still being created (cx-wb5.78): the view of a pane
/// Cmd+D shows before the daemon replied. Each key goes to the daemon at once by the terminal id
/// the app minted for the creation (`send {terminal_id}`, `terminal-input-while-creating-v1`); the
/// daemon queues it and writes it after the commit, before any later input. The app holds no keys.
///
/// The view's writer calls ``write(_:)`` one chunk at a time and awaits it, so every chunk sent
/// here is answered before the next one goes out. Once the view's attach target is known
/// (`targetKnown`), the next chunk goes by the attachment (`send {surface}`), which the daemon
/// writes after the queue: no chunk can pass another.
///
/// When the person closes the view before its terminal started (``close()``), no later chunk leaves
/// the app, and a daemon with `creating-input-cancel-v1` drops what it queued: a line typed into a
/// pane and then closed never runs in the shell the daemon is still starting.
public nonisolated final class CreatingTerminalInput: Sendable {
    /// The host terminal id the creation minted (the id a give-back names).
    public let terminalID: String
    private let connection: DaemonConnection
    private let targetKnown: @Sendable () -> Bool
    /// True once input goes by the attachment for good.
    private let done = Mutex(false)
    /// Whether the daemon serves `cancel-creating-input` (`creating-input-cancel-v1`).
    private let cancels: Bool
    /// True once the person closed the view (``close()``).
    private let closed = Mutex(false)

    public init(terminalID: String, connection: DaemonConnection, cancels: Bool = false, targetKnown: @escaping @Sendable () -> Bool) {
        self.terminalID = terminalID
        self.connection = connection
        self.cancels = cancels
        self.targetKnown = targetKnown
    }

    /// The person closed this view before its terminal started: from now on ``write(_:)`` drops every
    /// chunk, and a daemon that can is told once to drop the chunks it queued and to refuse the ones on
    /// their way (`cancel-creating-input`, on the connection that asked for the terminal). An older
    /// daemon is sent nothing: against it the queued chunks are still written after the commit. The
    /// cancel's reply is not awaited and its failure shows nothing: the pane is gone for the person.
    /// Returns whether a cancel was sent (the first call, to a daemon that takes it).
    @discardableResult
    public func close() -> Bool {
        let first = closed.withLock { was -> Bool in
            if was { return false }
            was = true
            return true
        }
        guard first, cancels else { return false }
        // task-owner: one cancel of a closed creation's queued input, ordered after the chunks already sent on this connection
        Task { [connection, terminalID] in _ = try? await connection.request(CancelCreatingInputRequest(terminalID: terminalID)) }
        return true
    }

    /// Sends `data` by the terminal id; false when it must go by the attachment instead (the
    /// target is known, or the daemon refused the id: the attach queue keeps it, as before).
    public func write(_ data: Data) async -> Bool {
        if closed.withLock({ $0 }) {
            // A closed view's chunk is taken and dropped while its terminal is not made: it goes neither to the
            // daemon nor to the attach queue. A terminal that started all the same (the daemon refused the
            // close and the view stayed) takes input by the attachment again.
            guard targetKnown() else { return true }
            done.withLock { $0 = true }
            return false
        }
        if done.withLock({ $0 }) { return false }
        if targetKnown() {
            done.withLock { $0 = true }
            return false
        }
        do {
            try await connection.sendTerminalInput(terminalID, bytes: data)
            return true
        } catch DaemonError.timedOut {
            // The daemon may hold the chunk: never send it twice (it gives back what it does not write).
            return true
        } catch {
            done.withLock { $0 = true }
            // The daemon refused a chunk of a view closed meanwhile (`input.cancelled`): dropped, not queued for the attach.
            return closed.withLock { $0 } && !targetKnown()
        }
    }
}
