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
/// - Alternate screen (vim, htop): the bytes pass through and the phone
///   claims its size as before, only while the page claims it (on screen, in
///   the foreground). Leaving the alternate screen releases it.
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

    public func send(_ bytes: Data) { inner.send(bytes) }
    public func sendReply(_ bytes: Data) { inner.sendReply(bytes) }
    public func stop() { inner.stop() }
    public func setOutputPaused(_ paused: Bool) { inner.setOutputPaused(paused) }
    public func noteInteraction() { inner.noteInteraction() }
    public func clearHistory() async throws { try await inner.clearHistory() }
    public func loadOlderHistory() { inner.loadOlderHistory() }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        let changed = phoneGrid.map { $0.columns != columns || $0.rows != rows } ?? true
        phoneGrid = (columns, rows)
        // Remembered by the Mac's session for a claim; sent only while it claims.
        if macClaims { inner.resize(columns: columns, rows: rows) }
        guard changed else { return }
        let segments = projection.setViewport(cols: UInt32(clamping: columns), rows: UInt32(clamping: rows))
        guard !shownAlternate, handler != nil else { return }
        log.notice("projection: phone grid \(columns, privacy: .public)x\(rows, privacy: .public), Mac keeps \(self.macGrid.columns, privacy: .public)x\(self.macGrid.rows, privacy: .public)")
        showGrid()
        emit(segments)
    }

    public func setClaimsSize(_ claims: Bool) {
        pageClaims = claims
        updateClaim()
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
            if resetPending {
                resetPending = false
                showReplay(projection.feed(bytes: data, paint: true))
            } else {
                emit(projection.feed(bytes: data, paint: true))
            }
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

    /// The phone claims its size only for the alternate screen, while the page claims.
    private func updateClaim() {
        let want = pageClaims && shownAlternate
        guard want != macClaims else { return }
        macClaims = want
        if want {
            macClaimsMade += 1
            if let grid = phoneGrid { inner.resize(columns: grid.columns, rows: grid.rows) }
            log.notice("projection: alternate screen on screen, claiming the phone's grid")
        } else {
            log.notice("projection: releasing the phone's grid (primary screen, or the page left)")
        }
        inner.setClaimsSize(want)
    }
}
#endif
