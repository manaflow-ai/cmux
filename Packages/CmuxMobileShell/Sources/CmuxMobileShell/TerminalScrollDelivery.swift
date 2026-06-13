import Foundation

struct TerminalScrollDelivery: Equatable, Sendable {
    let surfaceID: String
    var lines: Double
    var col: Int
    var row: Int

    mutating func append(_ delivery: TerminalScrollDelivery) {
        lines += delivery.lines
        col = delivery.col
        row = delivery.row
    }
}

struct TerminalScrollDeliveryQueue: Sendable {
    private var inFlight = false
    private var pending: TerminalScrollDelivery?

    var isIdle: Bool {
        !inFlight && pending == nil
    }

    mutating func enqueue(_ delivery: TerminalScrollDelivery) -> TerminalScrollDelivery? {
        guard inFlight else {
            inFlight = true
            return delivery
        }
        if var existing = pending {
            existing.append(delivery)
            pending = existing
        } else {
            pending = delivery
        }
        return nil
    }

    mutating func completeInFlight() -> TerminalScrollDelivery? {
        guard let next = pending else {
            inFlight = false
            return nil
        }
        pending = nil
        return next
    }

    mutating func reset() {
        inFlight = false
        pending = nil
    }
}
