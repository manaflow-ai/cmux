public import CmuxVisibleRows
public import Testing

/// Leo 2026-11-18 (ask-1105ee4cc6): "It's just text. It's literally just text. [...] we draw the visible area, right?
/// Like, that's what we're supposed to do." The visible-rows contract: a list whose length grows with the person's
/// data does the same work at 100 rows as at 10,000. For each size it builds the list in a window and asserts:
///
/// 1. Row views alive (shown and parked) <= the rows on screen plus the declared overscan (one viewport each side
///    by default), and flat in N.
/// 2. One item's change configures at most one row; one row of scroll configures only the rows that came in; a width
///    step lays out only the row views alive, once.
/// 3. Items walked per event are flat in N: no pass over every row to show one change.
///
/// "Flat" is within 10 percent (and 2) of the 100-row count. A list registers a `VisibleRowsFixture` and one test:
///
///     @Test func visibleRows() async throws { try await VisibleRowsContract.check(MyListFixture.self) }
///
/// A list that does not meet it yet registers the same way and is named in `VisibleRowsBaseline.knownFailures`
/// (one file, so the count of known failures is one number): `check` then runs it inside `withKnownIssue`. When its
/// fix lands the known issue stops happening, the test fails, and the fix takes the list out of the baseline. The
/// baseline only shrinks. scripts/cmux-next/lint (`visible-only-*` rules) finds lists not registered here.
@MainActor public enum VisibleRowsContract {
    /// The sizes every list is measured at.
    public static let sizes = [100, 10_000]
    /// Rows one step of one row's height can bring in: the row, and one cut by the edge.
    public static let rowsEnteringPerStep = 2

    /// One size's counts.
    public struct Measurement: Sendable, CustomStringConvertible {
        public var rows = 0, viewport = 0, alive = 0
        public var change = ListWorkMeter.Reading()
        public var scroll: ListWorkMeter.Reading?
        public var resize: ListWorkMeter.Reading?
        public var aliveAfterResize = 0

        public var description: String {
            "n=\(rows) viewport=\(viewport) alive=\(alive) change=\(change) scroll=\(scroll.map(\.description) ?? "-") "
                + "resize=\(resize.map(\.description) ?? "-")"
        }
    }

    /// Measures `fixture` at each of `sizes` (smallest first) and records an issue per broken rule; a list in
    /// `VisibleRowsBaseline.knownFailures` records them as known issues, and must record one. A list that already
    /// mounts every row at a smaller size is not built at the larger ones: rule 1 has failed, and an eager list of
    /// 10,000 row views takes minutes to build. Prints one `visible-rows <name>` line per size.
    @discardableResult
    public static func check<F: VisibleRowsFixture>(_ fixture: F.Type, sizes: [Int] = sizes,
                                                    sourceLocation: SourceLocation = #_sourceLocation) async throws -> [Measurement] {
        guard let known = VisibleRowsBaseline.knownFailures[F.name] else {
            return try await run(fixture, sizes: sizes, sourceLocation: sourceLocation)
        }
        var measured: [Measurement] = []
        await withKnownIssue(Comment(rawValue: "\(F.name) is in VisibleRowsBaseline: \(known.why)"), sourceLocation: sourceLocation) {
            // A list that cannot be built is a known issue too; the body throws nothing, so no overload rethrows.
            do { measured = try await run(fixture, sizes: sizes, sourceLocation: sourceLocation) } catch {
                Issue.record(error, sourceLocation: sourceLocation)
            }
        } matching: { issue in
            known.only.map { only in issue.comments.contains { $0.rawValue.contains(only) } } ?? true
        }
        return measured
    }

    static func run<F: VisibleRowsFixture>(_ fixture: F.Type, sizes: [Int], sourceLocation: SourceLocation) async throws -> [Measurement] {
        var measured: [Measurement] = []
        for n in sizes.sorted() {
            let m = try await measure(fixture, rows: n)
            measured.append(m)
            print("visible-rows \(F.name) \(m)")
            let bound = Int((Double(m.viewport) * (1 + 2 * F.overscanViewports)).rounded(.up))
            #expect(m.viewport > 0, "\(F.name): no rows on screen at n=\(n): the fixture shows nothing", sourceLocation: sourceLocation)
            #expect(m.alive <= bound, """
                \(F.name) holds \(m.alive) row views for \(m.viewport) rows on screen at n=\(n) (bound \(bound): the viewport \
                plus \(F.overscanViewports) viewport each side): give views only to rows in the viewport and its overscan
                """, sourceLocation: sourceLocation)
            #expect(m.change.rowsConfigured <= 1,
                    "\(F.name): one item's change configured \(m.change.rowsConfigured) rows at n=\(n): configure the changed row only",
                    sourceLocation: sourceLocation)
            if let scroll = m.scroll {
                #expect(scroll.rowsConfigured <= rowsEnteringPerStep, """
                    \(F.name): one row of scroll configured \(scroll.rowsConfigured) rows at n=\(n): configure only the rows \
                    that came into the overscan
                    """, sourceLocation: sourceLocation)
            }
            if let resize = m.resize {
                #expect(resize.rowsLaidOut <= max(m.alive, m.aliveAfterResize), """
                    \(F.name): one width step laid out \(resize.rowsLaidOut) rows for \(m.alive) row views at n=\(n): lay out \
                    the row views alive, once
                    """, sourceLocation: sourceLocation)
            }
            if m.alive > bound { break }
        }
        guard let small = measured.first, let large = measured.last, measured.count > 1 else { return measured }
        func flat(_ what: String, _ a: Int, _ b: Int) {
            #expect(b <= a + max(2, a / 10), "\(F.name): \(what) grew with the list: \(a) at n=\(small.rows), \(b) at n=\(large.rows)",
                    sourceLocation: sourceLocation)
        }
        flat("row views alive", small.alive, large.alive)
        let none = ListWorkMeter.Reading()
        let events: [(String, ListWorkMeter.Reading, ListWorkMeter.Reading)] = [
            ("one item's change", small.change, large.change),
            ("one row of scroll", small.scroll ?? none, large.scroll ?? none),
            ("one width step", small.resize ?? none, large.resize ?? none),
        ]
        for (event, a, b) in events {
            flat("rows configured per \(event)", a.rowsConfigured, b.rowsConfigured)
            flat("rows laid out per \(event)", a.rowsLaidOut, b.rowsLaidOut)
            flat("items walked per \(event)", a.itemsWalked, b.itemsWalked)
        }
        return measured
    }

    static func measure<F: VisibleRowsFixture>(_ fixture: F.Type, rows n: Int) async throws -> Measurement {
        let f = try await F(rows: n)
        defer { f.close() }
        var m = Measurement(rows: n)
        _ = f.list.listWork.take() // building it is not an event
        m.viewport = f.viewportRows
        m.alive = f.list.rowViewsAlive
        try await f.changeOneItem()
        m.change = f.list.listWork.take()
        if try await f.scrollOneRow() { m.scroll = f.list.listWork.take() }
        if try await f.resizeOneStep() {
            m.resize = f.list.listWork.take()
            m.aliveAfterResize = f.list.rowViewsAlive
        }
        return m
    }
}

/// A list built for the contract: the list over `rows` items in a window of a fixed size, and its three events, each
/// as the app delivers it. The window is the same at every size, so the viewport is too.
@MainActor public protocol VisibleRowsFixture {
    associatedtype List: VisibleRowsList
    /// The list's name in failures and in the printed `visible-rows` line.
    static var name: String { get }
    /// The overscan the list keeps, in viewports on each side (default 1; more than 2 needs a written reason).
    static var overscanViewports: Double { get }
    /// The list over `rows` items, in its window, laid out and drawn.
    init(rows: Int) async throws
    var list: List { get }
    /// Rows the viewport shows now.
    var viewportRows: Int { get }
    /// One shown item's data changes (a status line, an unread mark); returns once the list shows it.
    func changeOneItem() async throws
    /// The list scrolls by one row; false when it cannot (every row fits).
    func scrollOneRow() async throws -> Bool
    /// The list's width changes by one live-resize step; false when its width is fixed.
    func resizeOneStep() async throws -> Bool
    func close()
}

extension VisibleRowsFixture {
    public static var overscanViewports: Double { 1 }
}
