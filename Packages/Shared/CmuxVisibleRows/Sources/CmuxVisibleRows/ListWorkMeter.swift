/// One list's row work, for the visible-rows contract (Leo 2026-11-18, ask-1105ee4cc6: "we draw the visible area,
/// right? Like, that's what we're supposed to do."). A list whose length grows with the person's data keeps one meter
/// and counts where it does the work; `VisibleRowsContract` (CmuxVisibleRowsTesting) reads it per event at 100 and
/// 10,000 rows and asserts the work is the rows on screen, never the list:
///
/// - `rowsConfigured`: row views given a row's content (a new view, a reused one, a re-render of a shown one).
/// - `rowsLaidOut`: row frames computed or rows measured (a layout pass, a fitting size, a width change).
/// - `itemsWalked`: model items a pass read to show a change (a map, a compare, a search over the rows).
///
/// The meter belongs to its list, never to the process, so a test reads one list's work while other suites' lists
/// draw on the main actor. Counting is an add: it stays in release builds.
@MainActor public final class ListWorkMeter {
    /// The work counted since the last `take()`.
    public struct Reading: Equatable, Sendable, CustomStringConvertible {
        public var rowsConfigured = 0, rowsLaidOut = 0, itemsWalked = 0

        public init(rowsConfigured: Int = 0, rowsLaidOut: Int = 0, itemsWalked: Int = 0) {
            (self.rowsConfigured, self.rowsLaidOut, self.itemsWalked) = (rowsConfigured, rowsLaidOut, itemsWalked)
        }

        public var description: String { "(configured: \(rowsConfigured), laid out: \(rowsLaidOut), walked: \(itemsWalked))" }
    }

    public private(set) var reading = Reading()

    public init() {}

    public func configured(_ rows: Int = 1) { reading.rowsConfigured += rows }
    public func laidOut(_ rows: Int = 1) { reading.rowsLaidOut += rows }
    public func walked(_ items: Int) { reading.itemsWalked += items }
    /// Every one of `rows` made anew, measured and read: an eager list's rebuild.
    public func rebuilt(_ rows: Int) {
        configured(rows)
        laidOut(rows)
        walked(rows)
    }

    /// The work since the last call, then zero.
    public func take() -> Reading {
        defer { reading = Reading() }
        return reading
    }
}

/// A list the visible-rows contract measures: its work meter and the row views it holds.
@MainActor public protocol VisibleRowsList: AnyObject {
    var listWork: ListWorkMeter { get }
    /// Row views alive now, shown and parked for reuse: each is a subtree the UI framework lays out and walks.
    var rowViewsAlive: Int { get }
}
