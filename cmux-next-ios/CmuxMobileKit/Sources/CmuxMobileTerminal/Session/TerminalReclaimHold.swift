import Foundation

/// What a hidden terminal page does with the Mac's own grid (Leo, 2026-11-12:
/// "i swipe up into another app and it resize back... then i go to it again
/// and it resize again... surely this calculation of sort is doable on the
/// phone itself?").
///
/// A page that leaves the screen (the app in the background, another tab)
/// releases the phone's size (PROTOCOL.md "Terminal size claims"), so the
/// Mac's PTY goes back to the Mac's grid and replays it to the phone. Coming
/// back claims the phone's grid and the Mac replays a second time. The page
/// drew both: the Mac's wide grid, cut at the right edge, then the phone's
/// ("uncompact then squish").
///
/// The phone knows the grid it is about to claim, so it does not draw the
/// round trip:
/// - Hidden, a grid other than the phone's starts a hold: that grid and every
///   byte and alternate screen switch after it wait here, in order. The page
///   keeps the last frame it drew at its own grid.
/// - Shown again, the Mac's answer at the phone's grid ends the hold: what
///   was held is dropped. It is superseded: a grid change always comes with a
///   full replay, and the screen gets a reset before that replay (``Event``
///   `reset`) and the alternate screen state the replay is drawn in.
/// - Anything else shows what was held, in order, as it would have been
///   shown before (the Mac's policy keeps its own grid, no answer in
///   ``reclaimWait``, the stream ended, or more than ``maxBytes`` held).
public struct TerminalReclaimHold: Sendable {
    /// How long a claim may take to bring the phone's grid back before the
    /// held grid shows (the Mac answers a claim in one round trip).
    public static let reclaimWait: Duration = .milliseconds(1500)
    /// The most bytes held. Past it the hold shows what it has (the page is
    /// hidden, so no one sees it), never holding a hidden build log forever.
    public static let maxBytes = 8 << 20

    /// A grid, columns by rows.
    public struct Grid: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    /// The events held, in order (nil: not holding).
    public private(set) var held: [TerminalSessionEvent]?
    private var heldBytes = 0
    /// The alternate screen state the screen was last given.
    public private(set) var shownAlternate = false

    public init() {}

    public var isHolding: Bool { held != nil }

    /// An event for the screen (`.output`, `.alternateScreen`, `.hostGrid`):
    /// the events to give the screen now, in order.
    ///
    /// - Parameters:
    ///   - event: The event, in stream order.
    ///   - claims: The page claims the phone's size (it is on screen).
    ///   - phoneGrid: The grid the phone claims, when it has measured one.
    ///   - alternate: The alternate screen state after this event, as the
    ///     stream says (the session's `isAlternateScreen`).
    public mutating func take(_ event: TerminalSessionEvent, claims: Bool, phoneGrid: Grid?, alternate: Bool) -> [TerminalSessionEvent] {
        guard var events = held else {
            if case .hostGrid(let columns, let rows) = event, !claims, let phoneGrid,
               phoneGrid != Grid(columns: columns, rows: rows) {
                held = [event]
                heldBytes = 0
                return []
            }
            return shown([event])
        }
        if case .hostGrid(let columns, let rows) = event, claims, phoneGrid == Grid(columns: columns, rows: rows) {
            // The claim brought the phone's grid back: what was held is
            // superseded by the replay that follows.
            held = nil
            heldBytes = 0
            var out: [TerminalSessionEvent] = []
            if alternate != shownAlternate { out.append(.alternateScreen(alternate)) }
            out.append(event)
            out.append(.output(Self.reset))
            return shown(out)
        }
        events.append(event)
        if case .output(let data) = event { heldBytes += data.count }
        held = events
        return heldBytes > Self.maxBytes ? release() : []
    }

    /// Ends the hold: what was held, in order.
    public mutating func release() -> [TerminalSessionEvent] {
        guard let events = held else { return [] }
        held = nil
        heldBytes = 0
        return shown(events)
    }

    /// The stream starts over from a reset and a full replay (a reattach):
    /// what was held is superseded, and the hold goes on.
    public mutating func restart() {
        guard held != nil else { return }
        held = []
        heldBytes = 0
    }

    /// The full reset (RIS) the screen gets before a replay.
    public static let reset = Data("\u{1B}c".utf8)

    private mutating func shown(_ events: [TerminalSessionEvent]) -> [TerminalSessionEvent] {
        for case .alternateScreen(let on) in events { shownAlternate = on }
        return events
    }
}
