import Foundation

/// Connection-owned credit window for ordered input command receipts.
/// Access is confined to the connection's socket queue. A receipt certifies
/// command acceptance by cmux-tui, not execution by the shell or PTY host.
struct CloudTuiManualIOInputWindow {
    private let maximumInFlight = 32
    private var pending: [(write: CloudTuiManualIOWrite, needsReceipt: Bool)?] = []
    private var pendingIndex = 0
    private var inFlight: [CloudTuiManualIOReservation] = []

    mutating func append(_ write: CloudTuiManualIOWrite, needsReceipt: Bool) {
        // Admission already reserved the command's complete retained lifetime.
        pending.append((write: write, needsReceipt: needsReceipt))
    }

    mutating func next() -> CloudTuiManualIOWrite? {
        guard pendingIndex < pending.count, let command = pending[pendingIndex],
              !command.needsReceipt || inFlight.count < maximumInFlight else { return nil }
        pending[pendingIndex] = nil
        pendingIndex += 1
        if command.needsReceipt {
            inFlight.append(command.write.reservation)
        }
        if pendingIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingIndex = 0
        } else if pendingIndex >= 128 {
            pending.removeFirst(pendingIndex)
            pendingIndex = 0
        }
        return command.write
    }

    /// Input uses reserved request ID zero on this ordered connection. Each
    /// response retires one credit; receipts never cross a connection change.
    mutating func acknowledge() -> Bool {
        guard !inFlight.isEmpty else { return false }
        inFlight.removeFirst()
        return true
    }
}
