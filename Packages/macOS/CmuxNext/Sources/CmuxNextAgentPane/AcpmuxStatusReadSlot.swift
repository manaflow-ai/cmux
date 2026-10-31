import CmuxNextCompat

/// A pane can have one cached status read in flight. Menu refreshes share the connection's
/// lifetime without letting an untrusted page fan out Unix-socket connections.
nonisolated final class AcpmuxStatusReadSlot: Sendable {
    private let busy = Mutex(false)

    func begin() -> Bool {
        busy.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
    }

    func end() { busy.withLock { $0 = false } }
}
