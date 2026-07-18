import Foundation

struct TerminalScrollDelivery: Equatable, Sendable {
    let surfaceID: String
    var lines: Double
    var col: Int
    var row: Int
    var maxScrollbackRows: Int? = nil

    mutating func append(_ delivery: TerminalScrollDelivery) {
        lines += delivery.lines
        col = delivery.col
        row = delivery.row
        mergeMaxScrollbackRows(delivery.maxScrollbackRows)
    }

    mutating func mergeMaxScrollbackRows(_ incomingRows: Int?) {
        switch (maxScrollbackRows, incomingRows) {
        case (.some(let current), .some(let incoming)):
            maxScrollbackRows = max(current, incoming)
        case (nil, .some(let incoming)):
            maxScrollbackRows = incoming
        case (.some, nil), (nil, nil):
            break
        }
    }
}

struct TerminalScrollbackPrefetchState: Equatable, Sendable {
    static let defaultWindowRows = 600
    static let defaultRefreshDistanceRows = 120.0

    var windowRows: Int
    var refreshDistanceRows: Double
    private var hasPrimedWindow = false
    private var accumulatedRowsSincePrefetch = 0.0

    init(
        windowRows: Int = Self.defaultWindowRows,
        refreshDistanceRows: Double = Self.defaultRefreshDistanceRows
    ) {
        self.windowRows = max(0, windowRows)
        self.refreshDistanceRows = max(1, refreshDistanceRows)
    }

    mutating func rowsToPrefetch(forScrollLines lines: Double) -> Int? {
        guard lines != 0, windowRows > 0 else { return nil }
        accumulatedRowsSincePrefetch += abs(lines)
        guard !hasPrimedWindow || accumulatedRowsSincePrefetch >= refreshDistanceRows else {
            return nil
        }
        hasPrimedWindow = true
        accumulatedRowsSincePrefetch = 0
        return windowRows
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
        completeInFlight(completedDelivery: nil).next
    }

    mutating func completeInFlight(
        completedDelivery: TerminalScrollDelivery?
    ) -> TerminalScrollDeliveryCompletion {
        guard inFlight else {
            pending = nil
            return TerminalScrollDeliveryCompletion(
                next: nil,
                shouldDeliverScrollPrefetchRenderGrid: false
            )
        }
        guard let next = pending else {
            inFlight = false
            return TerminalScrollDeliveryCompletion(
                next: nil,
                shouldDeliverScrollPrefetchRenderGrid: true
            )
        }
        pending = nil
        var nextWithPrefetch = next
        nextWithPrefetch.mergeMaxScrollbackRows(completedDelivery?.maxScrollbackRows)
        return TerminalScrollDeliveryCompletion(
            next: nextWithPrefetch,
            shouldDeliverScrollPrefetchRenderGrid: false
        )
    }

    mutating func reset() {
        inFlight = false
        pending = nil
    }
}
