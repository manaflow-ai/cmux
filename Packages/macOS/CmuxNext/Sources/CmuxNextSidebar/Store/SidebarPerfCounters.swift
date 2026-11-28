import CmuxNextCompat
import Foundation

/// How much work the sidebar does, for `debug.sidebar_perf` and
/// scripts/cmux-next/sidebar-rows-perf-live.py. A script reads the counters
/// before and after a phase (agent status ticks, a scroll, a drag), so a
/// status tick shows as row patches and row configures, never as rebuilds.
///
/// - `rebuilds`: structural sidebar rebuilds (the App maps every row again).
/// - `section_sets`: structural `SidebarModel.setSections` calls (each arranges and compares every row).
/// - `list_reloads`: full list layouts (`SidebarLayout.make` + apply).
/// - `row_patches`: workspace rows updated in place.
/// - `row_configures`: row views configured (any path).
/// - `selection_patches`: selection changes drawn on the old and new rows only (no list layout).
/// - `scroll_realizes`: realize passes after a scroll.
/// - `ffi_calls`: calls into the Rust sidebar reducer (drag resolve, drop plan).
/// - `band_updates`: top/footer band content recomputes.
/// - `block_patches`: list blocks drawn again in place with every height kept (a pinned workspace's status or progress).
/// - `main_ns`: main-thread time spent in the measured paths, nanoseconds.
/// - `order_builds`: `SidebarModel.workspaceOrder` builds (one per structural change at most, never per query).
/// - `mirror_ns`: main-thread time in `SidebarMirror` calls (request encode, the Rust call, reading the reply), nanoseconds.
/// - `row_invalidations`: listed rows whose observed content changed (`SidebarRowFeed`): one change in one workspace
///   marks that workspace's row only, never every row (TYPING UNDER LOAD F6).
/// - `row_maps`: row mappings `SidebarRowFeed` ran (a new row, a dirty row, every row after an inputs change).
/// - `row_maps_unchanged`: rows a flush mapped that came out unchanged (no patch).
/// - `row_flushes`: flushes of the row feed that mapped rows; `row_maps` over the ticks of one ticking workspace stays at
///   or under 1 at any sidebar length (sidebar-stress-bench.py ticks `per_tick`, perf-gate.py status).
/// - `row_batch_runs`: synchronous calls a row map made on the main thread: each ``SidebarRowBatch`` run is one Rust call
///   (`cmux_sidebar_face_rows`) for every row it staged. `flush_sync_calls_max` is the most one row-feed flush made: one,
///   however many rows the flush maps and however long the sidebar (SidebarFlushSyncCallsTests, ask-5ad71ec59c).
/// - `row_views_made`: row views a list made while it applied rows (none for a new workspace row while the list's spare
///   waits: `SidebarListView.makeSpareRow`).
/// - `spare_row_views`: spare workspace row views made after a frame committed.
/// - `row_frames`: row frames a list apply computed (`SidebarListView.frame(for:)` in `apply`): the rows it can draw
///   (realized, in the realization rect, or reopened), never every listed row (m23, sidebar row insert and remove).
/// - `layout_rows`: rows `SidebarLayout.make` laid out (every listed row per full layout): a change that touches one row
///   lays out none, at 50 rows as at 200 (SIDEBAR INSERT: a create's row becoming its workspace's row).
/// - `row_cache_rows`: nodes the list's row caches took again in full (`rebuildRowCaches`, every listed node per full
///   reload): a change the list splices (an insert, a close, a move, a batch of them, a row's new height) takes none.
/// - `stuck_header_updates`: finds of the stuck project header (`SidebarListView.followStuckHeader`): one per scroll
///   frame, at 30 rows as at 3,000 (SIDEBAR-STICKY).
/// - `rows_walked`: listed rows a structural stage read to show a change: the nodes handed to `SidebarModel.setSections`
///   (it arranges and compares each), the nodes a list splice compared (`spliceInsertion`, `spliceRemoval`) and the
///   rows the scroll rule read (`viewport_rows`). One closed or new row must walk the rows that changed, at 60
///   workspaces as at 826 (WORKSPACE LIST 800).
/// - `viewport_rows`: rows the list's scroll rule read to keep what the user sees (`ListViewportChange` over the shown
///   and the new `SidebarLayout`): the rows in view and the rows that left or came beside them, never every listed
///   row (SIDEBAR ROW CHANGE stage 1). Counted in `rows_walked` too.
/// - `rows_made`: rows mapped from their stores (`SidebarRowFeed.Make.rows`), by the feed (its due rows) or by a caller
///   with no feed (every row it lists): one new workspace maps its own row, at 60 workspaces as at 826 (WORKSPACE LIST 800).
/// - `slot_rows`: rows `SidebarSection.withoutPlaceholders` walked and copied (a new workspace's slot rule).
/// - `doc_reshows`: `SidebarDocStore.reshow` calls (a create's placement: one, with one read of every live ref).
nonisolated enum SidebarPerfCounters {
    enum Counter: String, CaseIterable, Sendable {
        case rebuilds
        case sectionSets = "section_sets"
        case listReloads = "list_reloads"
        /// A group's fold drawn by splicing its rows (`SidebarListView.foldGroup`), no list reload.
        case groupFolds = "group_folds"
        /// Blocks drawn again in place, every height kept (`SidebarListView.patchBlocks`: a pinned workspace's status or
        /// progress), no list reload.
        case blockPatches = "block_patches"
        case rowPatches = "row_patches"
        case rowConfigures = "row_configures"
        case selectionPatches = "selection_patches"
        case scrollRealizes = "scroll_realizes"
        case ffiCalls = "ffi_calls"
        case bandUpdates = "band_updates"
        case mainNanoseconds = "main_ns"
        case mirrorNanoseconds = "mirror_ns"
        case orderBuilds = "order_builds"
        case rowInvalidations = "row_invalidations"
        case rowMaps = "row_maps"
        /// Rows a flush mapped again that came out as they were: work a change no row shows paid for.
        case rowMapsUnchanged = "row_maps_unchanged"
        /// Flushes of the row feed that mapped rows (at most one per display frame).
        case rowFlushes = "row_flushes"
        case rowViewsMade = "row_views_made"
        case spareRowViews = "spare_row_views"
        case rowFrames = "row_frames"
        case layoutRows = "layout_rows"
        /// Nodes the list's row caches took again in full (`rebuildRowCaches`): none for a change the list splices.
        case rowCacheRows = "row_cache_rows"
        /// A scroll frame or pass that found the stuck project header (`SidebarListView.followStuckHeader`): one per
        /// frame, whatever the group's size.
        case stuckHeaderUpdates = "stuck_header_updates"
        /// Listed rows a structural stage read (model set, list splice compare, list viewport) to show a change.
        case rowsWalked = "rows_walked"
        /// Rows the list's scroll rule read (the anchor, the settle): the rows in view, at any list length.
        case viewportRows = "viewport_rows"
        /// Rows mapped from their stores, with or without a feed (`SidebarRowFeed.Make.rows`).
        case rowsMade = "rows_made"
        /// Rows the slot rule's placeholder filter walked (`SidebarSection.withoutPlaceholders`).
        case slotRows = "slot_rows"
        /// `SidebarDocStore.reshow` calls.
        case docReshows = "doc_reshows"
        /// ``SidebarRowBatch`` runs: one synchronous Rust call each (`SidebarRowFeed.Make.rows`).
        case rowBatchRuns = "row_batch_runs"
        /// The most synchronous calls (``rowBatchRuns``) one row-feed flush made (`SidebarRowFeed.flush`).
        case flushSyncCallsMax = "flush_sync_calls_max"
    }

    private static let counts = Mutex<[Counter: Int]>([:])
    /// Per-caller counts of the costly counters ("list_reloads@SidebarView+Observation.swift:90"),
    /// so a breach names its cause (perf-gate.py prints them with the breach).
    private static let sources = Mutex<[String: Int]>([:])

    static func add(_ counter: Counter, _ amount: Int = 1) {
        guard amount != 0 else { return }
        counts.withLock { $0[counter, default: 0] += amount }
    }

    /// Rows the list's scroll rule read: `viewport_rows`, and `rows_walked` (a structural stage's rows).
    static func addViewportRows(_ amount: Int) {
        guard amount != 0 else { return }
        counts.withLock {
            $0[.viewportRows, default: 0] += amount
            $0[.rowsWalked, default: 0] += amount
        }
    }

    /// Raises `counter` to `value` if it is below (a high-water mark).
    static func raise(_ counter: Counter, to value: Int) {
        counts.withLock { $0[counter] = max($0[counter] ?? 0, value) }
    }

    /// The current count of `counter`.
    static func count(_ counter: Counter) -> Int { counts.withLock { $0[counter] ?? 0 } }

    /// `add`, also counted under its caller.
    static func add(_ counter: Counter, from file: StaticString, line: UInt) {
        add(counter)
        let name = "\(file)".split(separator: "/").last.map(String.init) ?? "\(file)"
        sources.withLock { $0["\(counter.rawValue)@\(name):\(line)", default: 0] += 1 }
    }

    /// Runs `body` and adds its duration to `main_ns`.
    static func timed<T>(_ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { add(.mainNanoseconds, Int(DispatchTime.now().uptimeNanoseconds &- start)) }
        return try body()
    }

    /// Runs `body` and adds its duration to `mirror_ns`.
    static func timedMirror<T>(_ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { add(.mirrorNanoseconds, Int(DispatchTime.now().uptimeNanoseconds &- start)) }
        return try body()
    }
    /// Every counter by name, then each caller count ("<counter>@<file>:<line>"); `reset` zeroes them after reading.
    static func report(reset: Bool) -> [String: Int] {
        var report = counts.withLock { values in
            var report: [String: Int] = [:]
            for counter in Counter.allCases { report[counter.rawValue] = values[counter] ?? 0 }
            if reset { values = [:] }
            return report
        }
        sources.withLock { values in
            report.merge(values) { counter, _ in counter }
            if reset { values = [:] }
        }
        return report
    }
}

extension SidebarView {
    /// `debug.sidebar_perf`: the sidebar work counters (`SidebarPerfCounters`).
    public static func perfCounters(reset: Bool) -> [String: Int] { SidebarPerfCounters.report(reset: reset) }

    /// The App rebuilt a window's sidebar rows from its stores (a structural change).
    public static func countRebuild() { SidebarPerfCounters.add(.rebuilds) }

    /// Runs the App's sidebar work `body`, adding its main-thread time to the counters.
    public static func timedPerf<T>(_ body: () throws -> T) rethrows -> T { try SidebarPerfCounters.timed(body) }
}
