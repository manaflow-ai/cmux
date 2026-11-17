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
/// Settings → Terminal → Fit to Phone turns this off (``isEnabled``): the
/// session is then used as it is and the Mac resizes to the phone.
@MainActor
public final class TerminalProjectingSession: TerminalSession {
    /// Whether new terminal pages project (Settings → Terminal → Fit to Phone off).
    public static var isEnabled: Bool { !CmuxMobilePreferences.terminalFitToPhone() }

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

    /// Size claims this session made on the Mac (for the sizing harness).
    public private(set) var macClaimsMade = 0
    /// When the phone claims its grid after all (the fit policy, in Rust).
    private let fit: TerminalFitPolicy
    /// A remembered program's first frames at the Mac's grid, held while
    /// the claim is on its way (`replay`: a reset's replay, shown as one).
    private var fitHold: (replay: Bool, segments: [ProjectionSegment])?
    private var fitHoldTimer: Task<Void, Never>?
    /// The longest the held frames wait for the Mac's answer; then they
    /// show at the Mac's grid (a Mac that keeps its grid: Prefer this Mac).
    static let fitHoldLimit: Duration = .milliseconds(1_500)

    public init(inner: any TerminalSession) {
        self.inner = inner
        macGrid = (inner.remoteColumns ?? 80, inner.remoteRows ?? 24)
        projection = TerminalProjection(hostCols: UInt32(clamping: macGrid.columns), hostRows: UInt32(clamping: macGrid.rows))
        fit = TerminalFitPolicy(remembered: TerminalFitMemory.programs)
        inner.setProjectsLocally(true)
        inner.setClaimsSize(false)
    }

    public var fitsToPhone: Bool? { fit.isFitted() }

    public func toggleFitToPhone() {
        let decision = fit.toggle()
        log.notice("projection: Fit to Phone toggled: \(decision.claims ? "fits" : "Mac's grid", privacy: .public) (\(decision.program ?? "-", privacy: .public))")
        apply(decision)
    }

    public var programName: String { inner.programName }
    public var isAlternateScreen: Bool { projection.isAlternate() }
    public var connectionState: TerminalConnectionState { inner.connectionState }
    public var clearsHistory: Bool { inner.clearsHistory }
    public var underlyingSession: AnyObject { inner.underlyingSession }

    /// The primary screen is the phone's own grid; the alternate screen the Mac's.
    public var remoteRows: Int? { shownAlternate ? inner.remoteRows : phoneGrid?.rows ?? inner.remoteRows }
    public var remoteColumns: Int? { shownAlternate ? inner.remoteColumns : phoneGrid?.columns }
    public var hostGridOwnerName: String? { shownAlternate ? inner.hostGridOwnerName : nil }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        self.handler = handler
        // Measured before the start: the page takes the phone's grid now; the
        // first bytes from the Mac are painted at it (a reset and the replay).
        if phoneGrid != nil, !shownAlternate { showGrid() }
        inner.start { [weak self] event in self?.innerEvent(event) }
    }

    public func send(_ bytes: Data) {
        inner.send(bytes)
        let decision = fit.typed(bytes: bytes)
        if decision.changed {
            log.notice("projection: typed into \(decision.program ?? "a TUI", privacy: .public): fitting it to the phone")
        }
        apply(decision)
    }
    public func sendReply(_ bytes: Data) { inner.sendReply(bytes) }
    public func stop() {
        fitHoldTimer?.cancel()
        inner.stop()
    }
    public func setOutputPaused(_ paused: Bool) { inner.setOutputPaused(paused) }
    public func noteInteraction() { inner.noteInteraction() }
    public func clearHistory() async throws { try await inner.clearHistory() }
    /// Older rows: the projection's own first (a re-wrap paints a window of
    /// the scrollback, so a rotation costs the same at any length), then the
    /// Mac's. Returns whether a reset with older rows follows (the
    /// projection's re-wrap, one still being parsed, or the Mac's replay).
    @discardableResult
    public func loadOlderHistory() -> Bool {
        guard !shownAlternate, handler != nil else { return inner.loadOlderHistory() }
        if projection.olderRows() > 0 {
            let started = CFAbsoluteTimeGetCurrent()
            // One chunk per replay: the page keeps calling while its reset is
            // parsed. Inside the throttle, the answer is the last load's: true
            // only while a reset it sent is still on its way.
            if let last = lastOlderLoad, started - last < 0.5 { return lastOlderLoadReset }
            lastOlderLoad = started
            let segments = projection.loadOlder(hostRows: Self.olderChunkRows)
            log.notice("projection: \(Self.olderChunkRows, privacy: .public) older rows re-wrapped in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000), privacy: .public) ms, \(self.projection.olderRows(), privacy: .public) left")
            emit(segments)
            lastOlderLoadReset = segments.contains { if case .reset = $0 { true } else { false } }
            return lastOlderLoadReset
        }
        return inner.loadOlderHistory()
    }

    /// A claim on the Mac (alternate screen) keeps its lease: the page renews
    /// it on leaving and coming back. The primary screen claims nothing.
    public func renewSizeClaim() { if macClaims { inner.renewSizeClaim() } }

    /// The Mac holds the scrollback the projection re-wraps: it asks for the
    /// reader's rows. Phone rows are never fewer than the host rows they wrap.
    public func requestHistoryRows(_ rows: Int) { inner.requestHistoryRows(rows) }

    public func noteReaderRowsFromEnd(_ rows: Int) {
        projection.setReaderRowsFromEnd(rows: UInt32(clamping: max(0, rows)))
    }

    private var lastOlderLoad: CFAbsoluteTime?
    /// Whether the last ``loadOlderHistory()`` re-wrap sent a reset.
    private var lastOlderLoadReset = false

    /// Mac scrollback rows each ``loadOlderHistory()`` re-wraps.
    static let olderChunkRows: UInt32 = 2_000

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
        apply(fit.setPagePresent(present: claims))
    }

    // MARK: Events

    private func innerEvent(_ event: TerminalSessionEvent) {
        switch event {
        case .output(let data):
            if data == TerminalReclaimHold.reset {
                // The Mac's replay follows: its bytes rebuild the model.
                _ = projection.feed(bytes: data, paint: false)
                projection.requestReset()
                resetPending = true
                return
            }
            let replay = resetPending
            resetPending = false
            let segments = projection.feed(bytes: data, paint: true)
            let decision = fit.observe(projection: projection, fallbackProgram: inner.programName)
            if decision.changed {
                log.notice("projection: \(decision.program ?? "the foreground", privacy: .public) \(decision.claims ? "fits the phone (\(decision.reason))" : "keeps the Mac's grid", privacy: .public)")
            }
            if fitHold != nil {
                // Held for a claim on its way: these bytes are at the Mac's grid too.
                if replay { fitHold = (true, segments) } else { fitHold?.segments += segments }
            } else if decision.changed, decision.claims, decision.reason == .remembered, projection.isAlternate() {
                // A program fitted before came to the foreground: its frames
                // at the Mac's grid wait for the Mac's answer to the claim.
                holdForFit(replay: replay, segments: segments)
            } else if replay {
                showReplay(segments)
            } else {
                emit(segments)
            }
            apply(decision)
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
            if shownAlternate { showGrid() }
        case .hostGridOwner(let name):
            if shownAlternate { handler?(.hostGridOwner(name)) }
        default:
            handler?(event)
        }
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
        handler?(.output(TerminalReclaimHold.reset))
        if !bytes.isEmpty { handler?(.output(bytes)) }
    }

    private func emit(_ segments: [ProjectionSegment]) {
        var pending = Data()
        func flush() {
            guard !pending.isEmpty else { return }
            handler?(.output(pending))
            pending = Data()
        }
        for segment in segments {
            switch segment {
            case .paint(let bytes), .raw(let bytes):
                pending.append(bytes)
            case .reset(let bytes):
                flush()
                handler?(.output(TerminalReclaimHold.reset))
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
            handler?(.alternateScreen(on))
            handler?(.hostGridOwner(on ? inner.hostGridOwnerName : nil))
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
        handler?(.hostGrid(columns: grid.columns, rows: grid.rows))
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

    /// The phone claims its size only when the fit policy says so (typed
    /// into a TUI, remembered, or chosen), while the page claims.
    private func updateClaim() {
        let want = fit.claims()
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
