import Foundation

/// Connection-owned credit window for ordered input command receipts.
/// Access is confined to the connection's socket queue. A receipt certifies
/// command acceptance by cmux-tui, not execution by the shell or PTY host.
struct CloudTuiManualIOInputWindow {
    private let maximumInFlight = 32
    private let maximumBytes = 256 * 1024
    private struct Command {
        let line: Data
        let needsReceipt: Bool
    }
    private var pending: [Command?] = []
    private var pendingIndex = 0
    private var inFlightSizes: [Int] = []
    private var retainedBytes = 0

    mutating func append(_ line: Data, needsReceipt: Bool) -> Bool {
        guard !line.isEmpty, line.count <= maximumBytes - retainedBytes else { return false }
        pending.append(Command(line: line, needsReceipt: needsReceipt))
        retainedBytes += line.count
        return true
    }

    mutating func next() -> Data? {
        guard pendingIndex < pending.count, let command = pending[pendingIndex],
              !command.needsReceipt || inFlightSizes.count < maximumInFlight else { return nil }
        pending[pendingIndex] = nil
        pendingIndex += 1
        if command.needsReceipt {
            inFlightSizes.append(command.line.count)
        } else {
            retainedBytes -= command.line.count
        }
        if pendingIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingIndex = 0
        } else if pendingIndex >= 128 {
            pending.removeFirst(pendingIndex)
            pendingIndex = 0
        }
        return command.line
    }

    /// Input uses reserved request ID zero on this ordered connection. Each
    /// response retires one credit; receipts never cross a connection change.
    mutating func acknowledge() -> Bool {
        guard !inFlightSizes.isEmpty else { return false }
        retainedBytes -= inFlightSizes.removeFirst()
        return true
    }
}
