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
/// - Alternate screen (vim, htop), by default: the bytes pass through and the
///   phone claims its size while the page claims it (on screen, in the
///   foreground); what the Mac drew at its own grid waits for the answer
///   (``claimHold``). Leaving the alternate screen releases it.
///
/// Settings → Terminal → Zoom Full-Screen Apps (off by default, ``zooms``):
/// - Alternate screen (vim, htop): the bytes pass through at the Mac's grid
///   and the page shows that grid scaled (pinch, double tap and pan:
///   `TerminalViewController+Zoom`). Viewing never resizes the Mac.
/// - The exception (`TerminalFitPolicy`, Rust `fit_policy`): typing text
///   into a TUI (the alternate screen, or an inline TUI such as Claude Code
///   on the primary screen) makes the phone claim its grid, only while the
///   page claims it (on screen, in the foreground). The program is
///   remembered (``TerminalFitMemory``): the next time it is in the
///   foreground the phone claims at once, and its frames at the Mac's grid
///   are held until the Mac answers (``fitHoldLimit``), so it never shows
///   scaled and then fitted. The program exiting or the page leaving
///   releases it; the title menu's Fit to Phone toggles it.
///
/// Settings → Terminal → Fit to Phone turns this off (``isEnabled``), and the
/// page menu's Fit to Phone per program (``isEnabled(for:)``): the session is
/// then used as it is and the Mac resizes to the phone.
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
    /// The page wants its size counted (``TerminalSizeClaimer``).
    private var pageClaims = true
    /// What the Mac's session was last told.
    private var macClaims = false
    /// What the screen was last told.
    private var shownAlternate = false
    private var shownGrid: (columns: Int, rows: Int)?
    /// The Mac's session reset its mirror: the replay that follows is shown
    /// as one reset and one chunk, like the Mac's own.
    private var resetPending = false
    private let log = Logger(subsystem: "dev.cmux.mobile", category: "terminal-sizing")

    /// How long a full-screen app's claim may take to bring the phone's grid
    /// before the Mac's grid shows (tests shorten it).
    public var reclaimWait: Duration = TerminalReclaimHold.reclaimWait

    /// A full-screen app came up at a Mac grid other than the phone's while
    /// the page claims its size (Leo, 2026-11-23: "im sometimes seeing these
    /// 118x69 load ins which are wide... then it properly goes"). The primary
    /// screen claims nothing, so a page that opens on a full-screen app
    /// attached at the Mac pane's grid and drew it, then the phone's once its
    /// claim was answered. What the screen would be told waits here, in
    /// order, until the Mac answers at the phone's grid (what waited is
    /// superseded by that answer's reset and replay) or ``reclaimWait`` passes
    /// (the Mac keeps its grid: what waited shows).
    private var claimHold: [TerminalSessionEvent]?
    /// The grid the screen had when the hold began.
    private var gridBeforeHold: (columns: Int, rows: Int)?
    private var claimHoldDeadline: Task<Void, Never>?

    /// Size claims this session made on the Mac (for the sizing harness).
    public private(set) var macClaimsMade = 0
    /// Settings → Terminal → Zoom Full-Screen Apps, read when the page opens:
    /// a full-screen app shows at the Mac's grid, zoomed, and claims only per
    /// ``fit``. Off, it claims the phone's grid as soon as it shows.
    public let zooms: Bool
    /// When the phone claims its grid after all (the fit policy, in Rust).
    private let fit: TerminalFitPolicy
    /// A remembered program's first frames at the Mac's grid, held while
    /// the claim is on its way (`replay`: a reset's replay, shown as one).
    private var fitHold: (replay: Bool, segments: [ProjectionSegment])?
    private var fitHoldTimer: Task<Void, Never>?
    /// The longest the held frames wait for the Mac's answer; then they
    /// show at the Mac's grid (a Mac that keeps its grid: Prefer this Mac).
    static let fitHoldLimit: Duration = .milliseconds(1_500)

    public init(inner: any TerminalSession, zooms: Bool = CmuxMobilePreferences.terminalZoomFullScreenApps()) {
        self.inner = inner
        self.zooms = zooms
        macGrid = (inner.remoteColumns ?? 80, inner.remoteRows ?? 24)
        projection = TerminalProjection(hostCols: UInt32(clamping: macGrid.columns), hostRows: UInt32(clamping: macGrid.rows))
        fit = TerminalFitPolicy(remembered: TerminalFitMemory.programs)
        inner.setProjectsLocally(true)
        inner.setClaimsSize(false)
    }

    public var fitsToPhone: Bool? { zooms ? fit.isFitted() : nil }

    public func toggleFitToPhone() {
        guard zooms else { return }
        let decision = fit.toggle()
        log.notice("projection: Fit to Phone toggled: \(decision.claims ? "fits" : "Mac's grid", privacy: .public) (\(decision.program ?? "-", privacy: .public))")
        apply(decision)
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
    /// Mac's. While a full-screen app's claim is out (``claimHold``), the grid
    /// the screen still has.
    public var remoteRows: Int? {
        if claimHold != nil { return (gridBeforeHold ?? phoneGrid)?.rows ?? inner.remoteRows }
        return shownAlternate ? inner.remoteRows : phoneGrid?.rows ?? inner.remoteRows
    }
    public var remoteColumns: Int? {
        if claimHold != nil { return (gridBeforeHold ?? phoneGrid)?.columns }
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
        typed(bytes)
    }
    public func sendReply(_ bytes: Data) { inner.sendReply(bytes) }
    /// The composer's Send goes to the Mac's session as one request. Without
    /// this the protocol's default (false) sent every projected terminal's
    /// Send through the mirror: the paste, then Return as a separate send
    /// 60 ms later, which a link blip could split (Leo, 2026-11-23: "the
    /// text goes through. But then the send doesn't go through").
    public func sendPasteAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void, maybeSent: @escaping @MainActor () -> Void) -> Bool {
        let sent = inner.sendPasteAndSubmit(text, notSent: notSent, maybeSent: maybeSent)
        if sent { typed(Data(text.utf8)) }
        return sent
    }
    public func sendTypedAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void, maybeSent: @escaping @MainActor () -> Void) -> Bool {
        let sent = inner.sendTypedAndSubmit(text, notSent: notSent, maybeSent: maybeSent)
        if sent { typed(Data(text.utf8)) }
        return sent
    }
    /// Zoom Full-Screen Apps: text typed into a TUI fits it to the phone (`fit_policy`).
    private func typed(_ bytes: Data) {
        guard zooms else { return }
        let decision = fit.typed(bytes: bytes)
        if decision.changed {
            log.notice("projection: typed into \(decision.program ?? "a TUI", privacy: .public): fitting it to the phone")
        }
        apply(decision)
    }
    public func stop() {
        fitHoldTimer?.cancel()
        claimHoldDeadline?.cancel()
        claimHoldDeadline = nil
        claimHold = nil
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
    public func discardHeldInput() { inner.discardHeldInput() }

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

    public func reportPaint(_ samples: [TerminalPaintTally.Sample]) {
        #if DEBUG
        onPaintReport?(samples)
        #endif
    }

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
        // Remembered by the Mac's session for a claim; sent only while it claims.
        if macClaims { inner.resize(columns: columns, rows: rows) }
        guard changed else { return }
        let started = CFAbsoluteTimeGetCurrent()
        let segments = projection.setViewport(cols: UInt32(clamping: columns), rows: UInt32(clamping: rows))
        let micros = Int((CFAbsoluteTimeGetCurrent() - started) * 1_000_000)
        guard !shownAlternate, handler != nil else { return }
        log.notice("projection: phone grid \(columns, privacy: .public)x\(rows, privacy: .public) re-wrapped in \(micros, privacy: .public) us (\(self.projection.olderRows(), privacy: .public) older rows on demand), Mac keeps \(self.macGrid.columns, privacy: .public)x\(self.macGrid.rows, privacy: .public)")
        showGrid()
        emit(segments)
    }

    public func setClaimsSize(_ claims: Bool) {
        pageClaims = claims
        // The page left: no claim will answer what waits.
        if !claims { releaseClaimHold() }
        if zooms { apply(fit.setPagePresent(present: claims)) } else { updateClaim() }
    }

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
            let decision = zooms ? fit.observe(projection: projection, fallbackProgram: inner.programName) : nil
            if let decision, decision.changed {
                log.notice("projection: \(decision.program ?? "the foreground", privacy: .public) \(decision.claims ? "fits the phone (\(decision.reason))" : "keeps the Mac's grid", privacy: .public)")
            }
            if fitHold != nil {
                // Held for a claim on its way: these bytes are at the Mac's grid too.
                if replay { fitHold = (true, segments) } else { fitHold?.segments += segments }
            } else if let decision, decision.changed, decision.claims, decision.reason == .remembered, projection.isAlternate() {
                // A program fitted before came to the foreground: its frames
                // at the Mac's grid wait for the Mac's answer to the claim.
                holdForFit(replay: replay, segments: segments)
            } else if replay {
                showReplay(segments)
            } else {
                emit(segments)
            }
            if !replay { schedulePaint() }
            if let decision { apply(decision) }
            let replies = projection.takeReplies()
            if !replies.isEmpty { inner.sendReply(replies) }
        case .alternateScreen:
            // The projection follows the bytes itself, in order.
            break
        case .hostGrid(let columns, let rows):
            macGrid = (columns, rows)
            projection.setHostGrid(cols: UInt32(clamping: columns), rows: UInt32(clamping: rows))
            if fitHold != nil, let phone = phoneGrid, columns <= phone.columns {
                // The Mac answered the claim: its reset and replay at the
                // phone's grid follow; the held frames are never shown.
                fitHold = nil
                fitHoldTimer?.cancel()
                log.notice("projection: the Mac fitted the phone's grid; held frames at its old grid dropped")
            }
            if claimHold != nil, let phone = phoneGrid, phone.columns == columns, phone.rows == rows { claimAnswered() }
            if shownAlternate { showGrid() }
        case .hostGridOwner(let name):
            if shownAlternate { deliver(.hostGridOwner(name)) }
        case .exited:
            releaseClaimHold()
            handler?(event)
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
        // Held for a claim on its way: the primary screen's paint waits behind
        // the held frames, in the Mac's order.
        if fitHold != nil { fitHold?.segments += segments } else { emit(segments) }
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
            // Back on the primary screen: the phone's own grid, nothing to wait for.
            if !on { releaseClaimHold() }
            shownAlternate = on
            if on, !zooms, pageClaims, let phone = phoneGrid, phone.columns != macGrid.columns || phone.rows != macGrid.rows {
                startClaimHold()
            }
            deliver(.alternateScreen(on))
            deliver(.hostGridOwner(on ? inner.hostGridOwnerName : nil))
        }
        showGrid()
        updateClaim()
    }

    /// The grid the screen's mirror takes: the phone's on the primary
    /// screen, the Mac's on the alternate screen.
    private func showGrid() {
        let grid = shownAlternate ? macGrid : (phoneGrid ?? macGrid)
        if let shown = shownGrid, shown.columns == grid.columns, shown.rows == grid.rows { return }
        shownGrid = grid
        deliver(.hostGrid(columns: grid.columns, rows: grid.rows))
    }

    // MARK: A full-screen app's first frame

    /// An event for the screen: held while a full-screen app's claim is out.
    private func deliver(_ event: TerminalSessionEvent) {
        if claimHold != nil {
            claimHold?.append(event)
        } else {
            handler?(event)
        }
    }

    private func startClaimHold() {
        guard claimHold == nil else { return }
        claimHold = []
        gridBeforeHold = shownGrid
        log.notice("projection: full-screen app at the Mac's \(self.macGrid.columns, privacy: .public)x\(self.macGrid.rows, privacy: .public): held until the phone's grid is answered")
        let wait = reclaimWait
        claimHoldDeadline = Task { @MainActor [weak self] in
            // A bounded deadline for the claim's answer, not a synchronization wait.
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, self.claimHold != nil else { return }
            self.log.notice("projection: the Mac kept its grid past the wait: the full-screen app shows at it")
            self.releaseClaimHold()
        }
    }

    /// The Mac answered at the phone's grid: its reset and replay follow and
    /// supersede the bytes held. The screen switches still go to it.
    private func claimAnswered() {
        claimHoldDeadline?.cancel()
        claimHoldDeadline = nil
        let held = claimHold ?? []
        claimHold = nil
        shownGrid = gridBeforeHold
        gridBeforeHold = nil
        for event in held {
            switch event {
            case .alternateScreen, .hostGridOwner: handler?(event)
            default: break
            }
        }
    }

    /// Shows what was held, in order.
    private func releaseClaimHold() {
        claimHoldDeadline?.cancel()
        claimHoldDeadline = nil
        guard let held = claimHold else { return }
        claimHold = nil
        gridBeforeHold = nil
        for event in held { handler?(event) }
    }

    /// A fit decision: persists the remembered programs and claims or releases.
    private func apply(_ decision: TerminalFitDecision) {
        if decision.rememberedChanged { TerminalFitMemory.programs = fit.remembered() }
        updateClaim()
    }

    /// Holds a remembered program's frames at the Mac's grid until the Mac
    /// answers the claim (``fitHoldLimit`` at most, then they show).
    private func holdForFit(replay: Bool, segments: [ProjectionSegment]) {
        // What the primary screen drew before the switch shows now.
        var before: [ProjectionSegment] = []
        var rest = segments[...]
        if !replay, let switchAt = segments.firstIndex(of: .alternate(on: true)) {
            before = Array(segments[..<switchAt])
            rest = segments[switchAt...]
        }
        if !before.isEmpty { emit(before) }
        fitHold = (replay, Array(rest))
        log.notice("projection: \(self.inner.programName, privacy: .public) fits at once (remembered): holding its frames at the Mac's grid for the claim")
        fitHoldTimer?.cancel()
        fitHoldTimer = Task { @MainActor [weak self] in
            try? await ContinuousClock().sleep(for: Self.fitHoldLimit)
            guard let self, !Task.isCancelled, let held = self.fitHold else { return }
            self.fitHold = nil
            self.log.notice("projection: no answer to the claim in time; showing the Mac's grid")
            if held.replay { self.showReplay(held.segments) } else { self.emit(held.segments) }
        }
    }

    /// The phone claims its size for the alternate screen while the page
    /// claims; with ``zooms``, only when the fit policy says so (typed into a
    /// TUI, remembered, or chosen), while the page claims.
    private func updateClaim() {
        let want = zooms ? fit.claims() : pageClaims && shownAlternate
        guard want != macClaims else { return }
        macClaims = want
        if want {
            macClaimsMade += 1
            if let grid = phoneGrid { inner.resize(columns: grid.columns, rows: grid.rows) }
            log.notice("projection: claiming the phone's grid (fit to phone)")
        } else {
            log.notice("projection: releasing the phone's grid (the program left, or the page did)")
        }
        inner.setClaimsSize(want)
    }
}
#endif
