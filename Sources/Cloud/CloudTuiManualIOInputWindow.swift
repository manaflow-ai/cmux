import Foundation

/// Connection-owned credit window for ordered input command receipts.
/// Access is confined to the connection's socket queue. A receipt certifies
/// command acceptance by cmux-tui, not execution by the shell or PTY host.
struct CloudTuiManualIOInputWindow {
    private let maximumInFlight = 32
    private let maximumBytes = 256 * 1024
    private var pending: [Data?] = []
    private var pendingIndex = 0
    private var inFlightSizes: [Int] = []
    private var retainedBytes = 0

    mutating func append(_ line: Data) -> Bool {
        guard !line.isEmpty, line.count <= maximumBytes - retainedBytes else { return false }
        pending.append(line)
        retainedBytes += line.count
        return true
    }

    mutating func next() -> Data? {
        guard inFlightSizes.count < maximumInFlight, pendingIndex < pending.count else { return nil }
        guard let line = pending[pendingIndex] else { return nil }
        pending[pendingIndex] = nil
        pendingIndex += 1
        inFlightSizes.append(line.count)
        if pendingIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingIndex = 0
        } else if pendingIndex >= 128 {
            pending.removeFirst(pendingIndex)
            pendingIndex = 0
        }
        return line
    }

    /// Input uses reserved request ID zero on this ordered connection. Each
    /// response retires one credit; receipts never cross a connection change.
    mutating func acknowledge() -> Bool {
        guard !inFlightSizes.isEmpty else { return false }
        retainedBytes -= inFlightSizes.removeFirst()
        return true
    }
}
