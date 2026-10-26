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
public nonisolated final class CreatingTerminalInput: CreatingTerminalInputSending {
    /// The host terminal id the creation minted (the id a give-back names).
    public let terminalID: String
    private let connection: DaemonConnection
    private let targetKnown: @Sendable () -> Bool
    /// True once input goes by the attachment for good.
    private let done = Mutex(false)

    public init(terminalID: String, connection: DaemonConnection, targetKnown: @escaping @Sendable () -> Bool) {
        self.terminalID = terminalID
        self.connection = connection
        self.targetKnown = targetKnown
    }

    /// True once input goes by the attachment for good: ``write(_:)`` would return false at once, so the
    /// caller sends without awaiting it.
    public var sendsByAttachment: Bool { done.withLock { $0 } }

    /// Sends `data` by the terminal id; false when it must go by the attachment instead (the
    /// target is known, or the daemon refused the id: the attach queue keeps it, as before).
    public func write(_ data: Data) async -> Bool {
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
            return false
        }
    }
}

/// Sends the input of a terminal still being created by its id (``CreatingTerminalInput``): the seam a
/// view's input drain awaits, one chunk at a time.
public nonisolated protocol CreatingTerminalInputSending: Sendable {
    /// True once input goes by the attachment for good.
    var sendsByAttachment: Bool { get }
    /// Sends `data` by the terminal id; false when it must go by the attachment instead.
    func write(_ data: Data) async -> Bool
}
