import CMUXMobileCore
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
        switch (maxScrollbackRows, delivery.maxScrollbackRows) {
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
    static let defaultMaxWindowRows = 4800

    var windowRows: Int
    var refreshDistanceRows: Double
    var maxWindowRows: Int
    private var hasPrimedWindow = false
    private var accumulatedRowsSincePrefetch = 0.0

    init(
        windowRows: Int = Self.defaultWindowRows,
        refreshDistanceRows: Double = Self.defaultRefreshDistanceRows,
        maxWindowRows: Int = Self.defaultMaxWindowRows
    ) {
        self.windowRows = max(0, windowRows)
        self.refreshDistanceRows = max(1, refreshDistanceRows)
        self.maxWindowRows = max(self.windowRows, maxWindowRows)
    }

    mutating func rowsToPrefetch(forScrollLines lines: Double) -> Int? {
        guard lines != 0, windowRows > 0 else { return nil }
        accumulatedRowsSincePrefetch += abs(lines)
        guard !hasPrimedWindow || accumulatedRowsSincePrefetch >= refreshDistanceRows else {
            return nil
        }
        // Sustained scrolling into history pages the window deeper so the
        // local mirror can keep going past the initial window; scrolling back
        // toward the bottom refreshes at the current depth instead.
        if hasPrimedWindow, lines > 0 {
            windowRows = min(windowRows + Self.defaultWindowRows, maxWindowRows)
        }
        hasPrimedWindow = true
        accumulatedRowsSincePrefetch = 0
        return windowRows
    }
}

extension TerminalScrollDelivery {
    /// Pure routing decision for a phone scroll gesture; nil means nothing is
    /// sent to the Mac.
    ///
    /// Primary screen: the phone's local Ghostty mirror owns the viewport, so
    /// no scroll delta is ever sent to the Mac; the only RPC is a
    /// `delta_lines = 0` scrollback-window fetch when the prefetch state says
    /// the local history needs (re)priming or deepening. Alternate screen: the
    /// wheel must reach the real PTY, so the delta is forwarded unchanged.
    static func forScrollGesture(
        surfaceID: String,
        activeScreen: MobileTerminalRenderGridFrame.Screen,
        lines: Double,
        col: Int,
        row: Int,
        prefetchState: inout TerminalScrollbackPrefetchState
    ) -> TerminalScrollDelivery? {
        guard activeScreen == .primary else {
            return TerminalScrollDelivery(surfaceID: surfaceID, lines: lines, col: col, row: row)
        }
        guard let maxScrollbackRows = prefetchState.rowsToPrefetch(forScrollLines: lines) else {
            return nil
        }
        return TerminalScrollDelivery(
            surfaceID: surfaceID,
            lines: 0,
            col: col,
            row: row,
            maxScrollbackRows: maxScrollbackRows
        )
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
        guard inFlight else {
            pending = nil
            return nil
        }
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
