import Foundation

/// One AppKit scroll event after cmux has applied its existing scroll-speed
/// normalization. The values intentionally stay in the same units that
/// libghostty receives, so a source that owns a rendered terminal can make
/// the same row decision without asking Ghostty to also mutate a local
/// viewport.
public struct TerminalManualScrollEvent: Equatable, Sendable {
    public let deltaX: Double
    public let deltaY: Double
    public let isPrecise: Bool
    public let cellHeightPixels: Double
    public let column: UInt16?
    public let row: UInt16?
    /// Crossterm-compatible modifier bits: shift=1, alt=2, control=4,
    /// super=8.
    public let modifiers: UInt8

    public init(
        deltaX: Double,
        deltaY: Double,
        isPrecise: Bool,
        cellHeightPixels: Double,
        column: UInt16?,
        row: UInt16?,
        modifiers: UInt8
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.isPrecise = isPrecise
        self.cellHeightPixels = cellHeightPixels
        self.column = column
        self.row = row
        self.modifiers = modifiers
    }
}

/// A semantic scroll request for a terminal owner whose protocol separates
/// viewport movement from raw PTY input (for example, Herdr).
public struct TerminalScrollCommand: Equatable, Sendable {
    public enum Direction: String, Equatable, Sendable {
        case up
        case down
    }

    public enum Source: String, Equatable, Sendable {
        case wheel
        case pageKey = "page_key"
    }

    public let direction: Direction
    public let lines: UInt16
    public let source: Source
    public let column: UInt16?
    public let row: UInt16?
    public let modifiers: UInt8

    /// A command must carry at least one line. Returning nil instead of
    /// silently clamping catches protocol bugs at the boundary.
    public init?(
        direction: Direction,
        lines: Int,
        source: Source,
        column: UInt16? = nil,
        row: UInt16? = nil,
        modifiers: UInt8 = 0
    ) {
        guard (1...Int(UInt16.max)).contains(lines) else { return nil }
        self.direction = direction
        self.lines = UInt16(lines)
        self.source = source
        self.column = column
        self.row = row
        self.modifiers = modifiers
    }
}

/// Converts the normalized AppKit delta into whole terminal rows. This is the
/// same truncation and remainder rule used by libghostty: precise deltas are
/// accumulated until one cell is crossed, while non-precise ticks represent
/// rows directly (with Darwin's minimum one-tick behavior).
public struct TerminalManualScrollQuantizer: Sendable {
    private var pendingPreciseVerticalPixels: Double = 0

    public init() {}

    /// Consumes one event. A nil result means a precise event did not yet
    /// cross a whole row, not that the event should be forwarded elsewhere.
    public mutating func command(
        for event: TerminalManualScrollEvent
    ) -> TerminalScrollCommand? {
        guard event.deltaY.isFinite, event.deltaY != 0 else { return nil }

        let signedRows: Int
        if event.isPrecise {
            guard event.cellHeightPixels.isFinite, event.cellHeightPixels > 0 else {
                return nil
            }
            pendingPreciseVerticalPixels += event.deltaY
            let amount = pendingPreciseVerticalPixels / event.cellHeightPixels
            guard abs(amount) >= 1 else { return nil }
            let whole = amount.rounded(.towardZero)
            guard whole != 0, let rows = Int(exactly: whole) else { return nil }
            pendingPreciseVerticalPixels -= whole * event.cellHeightPixels
            signedRows = rows
        } else {
            // Ghostty applies max(abs(delta), 1) to Darwin wheel ticks and
            // truncates toward zero after the configured multiplier.
            let magnitude = max(abs(event.deltaY), 1)
            let whole = magnitude.rounded(.towardZero)
            let rows = max(1, Int(whole))
            signedRows = event.deltaY > 0 ? rows : -rows
        }

        let direction: TerminalScrollCommand.Direction = signedRows > 0 ? .up : .down
        return TerminalScrollCommand(
            direction: direction,
            lines: abs(signedRows),
            source: .wheel,
            column: event.column,
            row: event.row,
            modifiers: event.modifiers
        )
    }

    /// Drops a fractional gesture remainder when the source is detached or
    /// changes terminal ownership.
    public mutating func reset() {
        pendingPreciseVerticalPixels = 0
    }
}
