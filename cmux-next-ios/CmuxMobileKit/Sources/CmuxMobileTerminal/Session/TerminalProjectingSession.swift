#if os(iOS)
import CmuxMobileDesign
import CmuxMobileLinkFFI
import Foundation
import os

/// The phone's own projection of a Mac terminal (Leo, 2026-11-12: "surely
/// this calculation of sort is doable on the phone itself? it projection of
/// text"). The Mac's PTY keeps the Mac pane's grid; the phone keeps a VT
/// model at that grid and shows it at its own grid
/// (`cmux-terminal-projection`, through CmuxMobileLinkFFI):
///
/// - Primary screen (a shell, Claude Code inline): the Mac's logical lines
///   re-wrapped at the phone's columns, as bytes for the phone's surface. This
///   phone never claims a size: attach, an app switch, a lock, the keyboard
///   and a rotation change nothing on the Mac, and a rotation re-wraps here
///   at once. The screen sees a session whose grid is the phone's own.
/// - Alternate screen (vim, htop): the bytes pass through at the Mac's grid
///   and the page shows that grid scaled to the phone (pinch, double tap and
///   pan: `TerminalViewController+Zoom`).
///
/// The phone never resizes the Mac's PTY while it projects (Leo, 2026-11-25:
/// "do everything at parity on the phone", "why would the Mac on an iPhone
/// connection ALWAYS be resized down anyways!?"): no claim on attach, on a
/// full-screen app, or on typing. Settings → Terminal → Fit to Phone off
/// (``isEnabled``), or the page menu's per program (``isEnabled(for:)``),
/// uses the Mac's session as it is.
@MainActor
public final class TerminalProjectingSession: TerminalSession {
    /// Whether new terminal pages project (Settings → Terminal → Fit to Phone off).
    public static var isEnabled: Bool { !CmuxMobilePreferences.terminalFitToPhone() }

    /// Whether a new page of `program` projects: its own Fit to Phone choice
    /// (the page menu), else the global setting (`TerminalFitToPhoneMemory`).
    public static func isEnabled(for program: String) -> Bool { !TerminalFitToPhoneMemory().fitToPhone(for: program) }

    /// The Mac's session.
    public let inner: any TerminalSession
    private let projection: TerminalProjection
    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
    /// The phone's grid (the screen's `resize`), nil until measured.
    private var phoneGrid: (columns: Int, rows: Int)?
    /// The Mac's PTY grid.
    private var macGrid: (columns: Int, rows: Int)
    /// What the screen was last told.
    private var shownAlternate = false
    private var shownGrid: (columns: Int, rows: Int)?
    /// The Mac's session reset its mirror: the replay that follows is shown
    /// as one reset and one chunk, like the Mac's own.
    private var resetPending = false
    private let log = Logger(subsystem: "dev.cmux.mobile", category: "terminal-sizing")


    /// Size claims this session made on the Mac (for the sizing harness): none.
    public let macClaimsMade = 0

    public init(inner: any TerminalSession) {
        self.inner = inner
        macGrid = (inner.remoteColumns ?? 80, inner.remoteRows ?? 24)
        projection = TerminalProjection(hostCols: UInt32(clamping: macGrid.columns), hostRows: UInt32(clamping: macGrid.rows))
        inner.setProjectsLocally(true)
        inner.setClaimsSize(false)
    }


    public var programName: String { inner.programName }
    public var isAlternateScreen: Bool { projection.isAlternate() }
    public var connectionState: TerminalConnectionState { inner.connectionState }
    public var clearsHistory: Bool { inner.clearsHistory }
    public var underlyingSession: AnyObject { inner.underlyingSession }
    public var tuiTranscriptRowsAbove: Int { Int(projection.transcriptRowsAbove()) }

    public func tuiTranscript() -> TerminalTUITranscript? {
        projection.transcriptPaint().map {
            TerminalTUITranscript(bytes: $0.bytes, rows: Int($0.rows), screenTop: Int($0.screenTop))
        }
    }

    /// The primary screen is the phone's own grid; the alternate screen the
    /// Mac's.
    public var remoteRows: Int? {
        return shownAlternate ? inner.remoteRows : phoneGrid?.rows ?? inner.remoteRows
    }
    public var remoteColumns: Int? {
        return shownAlternate ? inner.remoteColumns : phoneGrid?.columns
    }
    public var hostGridOwnerName: String? { shownAlternate ? inner.hostGridOwnerName : nil }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        self.handler = handler
        // Measured before the start: the page takes the phone's grid now; the
        // first bytes from the Mac are painted at it (a reset and the replay).
        if phoneGrid != nil, !shownAlternate { showGrid() }
        inner.start { [weak self] event in self?.innerEvent(event) }
    }

    public func send(_ bytes: Data) {
        // A key shows the app's live screen first: what it answers draws there.
        returnToLiveScreen()
        inner.send(bytes)
    }
    public func sendReply(_ bytes: Data) { inner.sendReply(bytes) }
    /// The composer's Send goes to the Mac's session as one request. Without
    /// this the protocol's default (false) sent every projected terminal's
    /// Send through the mirror: the paste, then Return as a separate send
    /// 60 ms later, which a link blip could split (Leo, 2026-11-23: "the
    /// text goes through. But then the send doesn't go through").
    public func sendPasteAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void, maybeSent: @escaping @MainActor () -> Void) -> Bool {
        let sent = inner.sendPasteAndSubmit(text, notSent: notSent, maybeSent: maybeSent)
        return sent
    }
    public func sendTypedAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void, maybeSent: @escaping @MainActor () -> Void) -> Bool {
        let sent = inner.sendTypedAndSubmit(text, notSent: notSent, maybeSent: maybeSent)
        return sent
    }
    public func stop() {
        inner.stop()
    }
    public func setOutputPaused(_ paused: Bool) { inner.setOutputPaused(paused) }
    public func noteInteraction() { inner.noteInteraction() }
    public func clearHistory() async throws { try await inner.clearHistory() }
    /// Older rows: the projection's own first (a re-wrap paints a window of
    /// the scrollback, so a rotation costs the same at any length), then the
    /// Mac's. Returns whether a reset with older rows follows (the
    /// projection's re-wrap or the Mac's replay).
    ///
    /// The answer keeps the session contract the page is written against
    /// (``TerminalSession/loadOlderHistory()``, as `DaemonTerminalSession`
    /// keeps it): true means the reset comes *after* this call returns, never
    /// inside it, and always comes. The page records that it asked only once
    /// the call returns (`olderRowsAsked`), so a reset sent inside the call
    /// was taken for some other replay and the page waited for one that never
    /// came; and a call inside the throttle that answered true without a load
    /// left it waiting too.
    @discardableResult
    public func loadOlderHistory() -> Bool {
        guard !shownAlternate, handler != nil else { return inner.loadOlderHistory() }
        // One re-wrap at a time: the page keeps calling while the reset it
        // asked for is on its way or being parsed; those calls join it.
        if olderLoadScheduled { return true }
        guard projection.olderRows() > 0 else { return inner.loadOlderHistory() }
        olderLoadScheduled = true
        // One chunk per replay (the page keeps calling while a replay is
        // parsed): at most one re-wrap per `olderLoadInterval`, the next one
        // when that has passed.
        let now = CFAbsoluteTimeGetCurrent()
        let wait = lastOlderLoad.map { max(0, $0 + Self.olderLoadInterval - now) } ?? 0
        Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            self?.loadOlderNow()
        }
        return true
    }

    /// The re-wrap ``loadOlderHistory()`` promised, on a later turn of the
    /// main actor.
    private func loadOlderNow() {
        olderLoadScheduled = false
        guard !shownAlternate, handler != nil else { return }
        let started = CFAbsoluteTimeGetCurrent()
        lastOlderLoad = started
        guard projection.olderRows() > 0 else {
            // A replay since the ask holds them all already: the Mac's own.
            inner.loadOlderHistory()
            return
        }
        let segments = projection.loadOlder(hostRows: Self.olderChunkRows)
        log.notice("projection: \(Self.olderChunkRows, privacy: .public) older rows re-wrapped in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000), privacy: .public) ms, \(self.projection.olderRows(), privacy: .public) left")
        emit(segments)
    }

    /// The Mac holds the scrollback the projection re-wraps: it asks for the
    /// reader's rows. Phone rows are never fewer than the host rows they wrap.
    public func requestHistoryRows(_ rows: Int) { inner.requestHistoryRows(rows) }
    /// A pan's frame times go to the Mac the same way under a projection (`phone-frames`).
    public func reportScrollFrames(_ pan: TerminalPanFrames) { inner.reportScrollFrames(pan) }
    /// Paint reports go to the Mac's session too: without this the default (projection) sent none.
    /// DEBUG: the bench's ``onPaintReport`` sees them as well.
    public func reportPaint(_ samples: [TerminalPaintTally.Sample]) {
        #if DEBUG
        onPaintReport?(samples)
        #endif
        inner.reportPaint(samples)
    }
    public func discardHeldInput() { inner.discardHeldInput() }
    public func beginAttachmentSubmission(onExpire: @escaping @MainActor () -> Void) -> UUID {
        inner.beginAttachmentSubmission(onExpire: onExpire)
    }
    @discardableResult public func endAttachmentSubmission(_ id: UUID) -> Bool {
        inner.endAttachmentSubmission(id)
    }

    public func noteReaderRowsFromEnd(_ rows: Int) {
        projection.setReaderRowsFromEnd(rows: UInt32(clamping: max(0, rows)))
    }

    // MARK: Held rows (Leo, 2026-11-23: "if the data was sent through... why
    // cant you simply scroll through the depiction that was already given?")

    /// Rust decides: within the rows the app scrolled off, the phone paints
    /// them (nothing is sent), also for an app that asked for the mouse;
    /// past them, or with nothing held, the wheel goes to the Mac as before.
    public func panHeldRows(_ rows: Double) -> Double {
        #if DEBUG
        guard holdsRows else { return rows }
        let gestureMs = TerminalPaintReport.nowMs
        #endif
        let step = projection.altPan(rows: rows)
        if !step.paint.isEmpty {
            handler?(.output(step.paint))
            #if DEBUG
            heldPaints += 1
            if stampsPans {
                // Gesture to paint: the present that shows these bytes.
                panSeq += 1
                handler?(.paintMark(seq: -panSeq, receivedMs: gestureMs))
            }
            #endif
        }
        return step.forwardRows
    }

    public func returnToLiveScreen() {
        let live = projection.altReturnLive()
        if !live.isEmpty { handler?(.output(live)) }
    }

    /// Rows held for a pan over the alternate screen, and their bytes (tests, the bench).
    public var heldRows: (rows: Int, bytes: Int) {
        let held = projection.held()
        return (Int(clamping: held.rows), Int(clamping: held.bytes))
    }

    /// How many held rows back the screen shows the app (0: live).
    public var heldRowsBack: Int { Int(projection.altRowsBack()) }

    #if DEBUG
    /// DEBUG bench (`tuiheld`): false sends every pan to the app, as before held rows.
    public var holdsRows = true
    /// DEBUG bench: pans painted from held rows.
    public private(set) var heldPaints = 0
    /// DEBUG bench: stamps each held-row paint with its gesture's time
    /// (`.paintMark`, negative seq), for gesture-to-paint.
    public var stampsPans = false
    private var panSeq = 0
    /// DEBUG bench: what the screen reported painted.
    public var onPaintReport: (@MainActor ([TerminalPaintTally.Sample]) -> Void)?
    #endif


    private var lastOlderLoad: CFAbsoluteTime?
    /// A ``loadOlderHistory()`` re-wrap is promised and not sent yet.
    private var olderLoadScheduled = false
    /// The least time between two older-row re-wraps (seconds).
    static let olderLoadInterval: CFAbsoluteTime = 0.5

    /// Mac scrollback rows each ``loadOlderHistory()`` re-wraps.
    static let olderChunkRows: UInt32 = 2_000

    // MARK: Find

    /// The Mac's `terminal-find` pages, their hits laid on the phone's re-wrapped rows
    /// (`TerminalProjection.locate`, in Rust): `rowsFromBottom` and the columns are the phone's, and
    /// the markers keep only their difference (the rows a match spans). Hits the projection does not
    /// hold (older than its model) are left out. A full-screen app, and a Mac without the command,
    /// answer nil: the page searches its own rows.
    public func findPage(_ request: TerminalFindRequest) async throws -> TerminalFindPage? {
        guard !shownAlternate, let page = try await inner.findPage(request) else { return nil }
        return Self.relocated(page) { [projection] rows, column in
            projection.locate(hostFromBottom: UInt64(clamping: rows), hostColumn: UInt32(clamping: column))
                .map { (rowsFromBottom: Int(clamping: $0.fromBottom), column: Int($0.column)) }
        }
    }

    /// The phone's rows are the projection's own, whole: no rows omitted or skipped.
    public var findMirror: TerminalFindMirror? {
        guard !shownAlternate, inner.findMirror != nil else { return nil }
        return TerminalFindMirror(omitted: 0, skipped: 0, windowRows: nil)
    }

    /// A match older than the phone's rows: the projection re-wraps more of what it holds, then the
    /// Mac's own replay (`loadOlderHistory`).
    public func loadHistory(aroundDaemonRow daemonRow: Int, rowsFromBottom: Int) -> Bool { loadOlderHistory() }

    /// `page` with every hit moved through `locate` (host rows from the bottom and column -> phone's).
    /// Pure, so callers on any actor (its tests) can run it.
    nonisolated static func relocated(
        _ page: TerminalFindPage,
        locate: (_ rowsFromBottom: Int, _ column: Int) -> (rowsFromBottom: Int, column: Int)?
    ) -> TerminalFindPage {
        var page = page
        page.hits = page.hits.compactMap { hit in
            let hostSpan = max(0, hit.end.marker - hit.start.marker)
            guard let start = locate(hit.rowsFromBottom, hit.start.column),
                  let end = locate(max(1, hit.rowsFromBottom - hostSpan), hit.end.column) else { return nil }
            let span = max(0, start.rowsFromBottom - end.rowsFromBottom)
            return TerminalFindPage.Hit(
                start: .init(marker: 0, column: start.column), end: .init(marker: span, column: end.column),
                rowsFromBottom: start.rowsFromBottom, snippet: hit.snippet)
        }
        return page
    }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        let changed = phoneGrid.map { $0.columns != columns || $0.rows != rows } ?? true
        phoneGrid = (columns, rows)
        // The Mac keeps its grid: the phone re-wraps at its own.
        guard changed else { return }
        let started = CFAbsoluteTimeGetCurrent()
        let segments = projection.setViewport(cols: UInt32(clamping: columns), rows: UInt32(clamping: rows))
        let micros = Int((CFAbsoluteTimeGetCurrent() - started) * 1_000_000)
        guard !shownAlternate, handler != nil else { return }
        log.notice("projection: phone grid \(columns, privacy: .public)x\(rows, privacy: .public) re-wrapped in \(micros, privacy: .public) us (\(self.projection.olderRows(), privacy: .public) older rows on demand), Mac keeps \(self.macGrid.columns, privacy: .public)x\(self.macGrid.rows, privacy: .public)")
        showGrid()
        emit(segments)
    }


    /// The page's size claim: the phone claims nothing while it projects.
    public func setClaimsSize(_ claims: Bool) {}

    // MARK: Events

    private func innerEvent(_ event: TerminalSessionEvent) {
        if case .output = event {} else { flushPaint() }
        switch event {
        case .output(let data):
            if data == TerminalReclaimHold.reset {
                // The Mac's replay follows: its bytes rebuild the model, and
                // the replay's paint (a reset) holds whatever waited to paint.
                paintScheduled = false
                _ = projection.feed(bytes: data, paint: false)
                projection.requestReset()
                resetPending = true
                return
            }
            let replay = resetPending
            resetPending = false
            // A replay paints at once (its reset holds whatever waited to
            // paint); any other chunk is parsed now and painted once for every
            // chunk that arrived before the main thread got to it
            // (`flushPaint`). Switches to and from the alternate screen still
            // come back here, in order, with what the primary drew before them.
            if replay { paintScheduled = false }
            let segments = projection.feed(bytes: data, paint: replay)
            if replay { showReplay(segments) } else { emit(segments) }
            if !replay { schedulePaint() }
            let replies = projection.takeReplies()
            if !replies.isEmpty { inner.sendReply(replies) }
        case .alternateScreen:
            // The projection follows the bytes itself, in order.
            break
        case .hostGrid(let columns, let rows):
            macGrid = (columns, rows)
            projection.setHostGrid(cols: UInt32(clamping: columns), rows: UInt32(clamping: rows))
            if shownAlternate { showGrid() }
        case .hostGridOwner(let name):
            if shownAlternate { deliver(.hostGridOwner(name)) }
        default:
            handler?(event)
        }
    }

    // MARK: One paint for a backlog

    /// A paint waits for the chunks queued behind the one that asked for it.
    private var paintScheduled = false
    /// When the last paint ran, and which schedule a pending paint belongs to
    /// (a paint an event already flushed leaves its timer behind).
    private var lastPaint: DispatchTime?
    private var paintGeneration = 0
    /// One display frame: the most often the phone paints.
    private static let paintInterval: DispatchTimeInterval = .nanoseconds(16_666_667)
    /// Paints made, and output chunks they covered (for tests and the
    /// paint harness): a backlog of N chunks is one paint, not N.
    public private(set) var paintsMade = 0
    public private(set) var chunksFed = 0

    /// Each Mac chunk used to be re-wrapped and painted on its own, on the
    /// main thread: at 70 chunks a second and 13 to 19 ms a paint on a phone
    /// the backlog grew faster than it drained (Leo, 2026-11-22: "the scroll
    /// occurs ... on mac / then it delays on my actual iphone display").
    /// Now the chunks are parsed as they come and painted at most once per
    /// display frame: on the next turn of the main queue (after every chunk
    /// already waiting on it), or a frame after the last paint if that is
    /// later. A backlog costs one paint, and a lone keystroke echo waits no
    /// frame.
    private func schedulePaint() {
        chunksFed += 1
        guard !paintScheduled else { return }
        paintScheduled = true
        paintGeneration &+= 1
        let generation = paintGeneration
        let paint: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.paintGeneration == generation else { return }
                self.flushPaint()
            }
        }
        if let lastPaint, lastPaint + Self.paintInterval > .now() {
            DispatchQueue.main.asyncAfter(deadline: lastPaint + Self.paintInterval, execute: paint)
        } else {
            DispatchQueue.main.async(execute: paint)
        }
    }

    /// Paints what the chunks since the last paint changed (nothing on the
    /// alternate screen, whose bytes went through as they came). Runs before
    /// any other event, so the screen sees every event in the Mac's order.
    private func flushPaint() {
        guard paintScheduled else { return }
        paintScheduled = false
        lastPaint = .now()
        paintsMade += 1
        let segments = projection.flush()
        emit(segments)
    }

    /// A reset and its replay: the alternate screen state and grid the replay
    /// ends in first, then one reset and the replay's bytes as one chunk.
    private func showReplay(_ segments: [ProjectionSegment]) {
        var bytes = Data()
        for segment in segments {
            switch segment {
            case .paint(let chunk), .reset(let chunk), .raw(let chunk): bytes.append(chunk)
            case .alternate: break
            }
        }
        setShownAlternate(projection.isAlternate())
        deliver(.output(TerminalReclaimHold.reset))
        if !bytes.isEmpty { deliver(.output(bytes)) }
    }

    private func emit(_ segments: [ProjectionSegment]) {
        var pending = Data()
        func flush() {
            guard !pending.isEmpty else { return }
            deliver(.output(pending))
            pending = Data()
        }
        for segment in segments {
            switch segment {
            case .paint(let bytes), .raw(let bytes):
                pending.append(bytes)
            case .reset(let bytes):
                flush()
                deliver(.output(TerminalReclaimHold.reset))
                pending = bytes
            case .alternate(let on):
                flush()
                setShownAlternate(on)
            }
        }
        flush()
    }

    private func setShownAlternate(_ on: Bool) {
        if on != shownAlternate {
            shownAlternate = on
            deliver(.alternateScreen(on))
            deliver(.hostGridOwner(on ? inner.hostGridOwnerName : nil))
        }
        showGrid()
    }

    /// The grid the screen's mirror takes: the phone's on the primary
    /// screen, the Mac's on the alternate screen.
    ///
    /// The primary screen's grid is held until the phone has measured its own
    /// (`resize`): it never falls back to the Mac's. That fallback told the page
    /// the Mac pane's grid (118x69 on Leo's Mac) whenever a replay or a screen
    /// switch came in before the first measure, so the page laid the mirror out
    /// at the Mac's width and panned sideways, then took the phone's grid a
    /// moment later (Leo, 2026-11-23: "im sometimes seeing these 118x69 load
    /// ins which are wide... then it properly goes").
    private func showGrid() {
        if !shownAlternate, phoneGrid == nil { return }
        let grid = shownAlternate ? macGrid : (phoneGrid ?? macGrid)
        if let shown = shownGrid, shown.columns == grid.columns, shown.rows == grid.rows { return }
        shownGrid = grid
        deliver(.hostGrid(columns: grid.columns, rows: grid.rows))
    }

    private func deliver(_ event: TerminalSessionEvent) { handler?(event) }
}
#endif
