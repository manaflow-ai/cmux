import AppKit
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import os

/// Bridges one daemon terminal attachment (`TerminalAttachment`) to a
/// Ghostty surface (`TerminalIO`).
///
/// The attachment lifecycle is one `TerminalAttachMachine` run by a
/// `TerminalAttachDriver` (state-audit.md T1, T3-T5):
/// - Attaches on its own connection without claiming geometry, so showing a
///   tab never reflows the PTY. The first settled grid report after the
///   replay claims it while the view renders (SurfaceLedger visibility).
/// - Input typed while attaching or reattaching is queued and sent once, in
///   order, after the replay. Grid reports meanwhile are coalesced.
/// - Maps replays (plain or with Kitty state) and output in order through a
///   bounded step queue; a replay is preceded by its grid so the mirror
///   sizes before parsing it. A daemon `resized` is only a grid change.
/// - `overflow` (this view fell behind, the daemon's 8 MiB limit) detaches
///   the old link and reattaches for a fresh replay.
/// - Closing during an attach ends the view at once and detaches the link
///   the attach returns, with its lease, as soon as it completes.
/// - Geometry follows the latest active client (`TerminalAttachMachine`):
///   a visible view claims on each settled resize and, after another client
///   sized the terminal, on its next key press or focus.
/// - Grid reports go through `ResizeCoordinator` and reach the daemon the
///   next frame, one grid in flight per terminal (a drag reflows live).
/// - A dropped stream or failed attach leaves the view disconnected (last
///   screen and a status label). A visible view re-attaches by itself after
///   a capped backoff (500 ms doubling to 30 s, cx-wwtam) until an attach works, offering Retry
///   after about 90 s; a hidden one waits for an event: shown again, a key press, a click, focus or
///   Retry, or the App's ``reconnect()``. A restored view says "Restoring…" until its first replay
///   and, for its first 90 s or so, retries every 2 s at most until then (#23029).
///   ``processExited()`` ends it until the daemon reports the terminal
///   running again (``processRevived()``, R41).
nonisolated final class DaemonTerminalIO: TerminalIO {
    struct Target: Sendable {
        var attachment: TerminalAttachment.Target
        var initialSize: CellSize
        /// The user's Ghostty cursor: a replay's cursor restore never overrides it.
        var cursorDefault: TerminalCursorDefault = .ghostty
    }

    let events: AsyncStream<TerminalIOEvent>
    private let driver: TerminalAttachDriver<TerminalAttachment>
    private let creatingInput: CreatingTerminalInput?
    /// The target's surface id for the typing probe (0: not resolved at init, a terminal still being made).
    private let probeSurface: UInt64
    /// The burst bench's grid echo and first-output marks (nil: none; a Release build compiles them out).
    private let burstTrace: BurstTrace?
    /// The app's grid sender (`AppServices.resizes`): next frame, one in flight, a final grid now.
    private let resizes: ResizeCoordinator
    /// The id of the terminal still being created whose keys go to the daemon by id, nil otherwise.
    var creatingTerminalID: String? { creatingInput?.terminalID }

    /// - Parameter policyBlocked: true while an administrator turned off the
    ///   feature that reaches this terminal's machine: every disconnect shows
    ///   "Turned off by your organization" and the endpoint refuses re-attaches.
    /// `gate`: the view of a terminal not created yet attaches only once the gate names it.
    /// `burstTrace`: where the grids this view sends, their echoes and its first output after each echo
    /// go while the burst bench records (`debug.burst`).
    /// `resizes`: the app's grid sender (``ResizeCoordinator``), from its composition root.
    init(target: Target, resizes: ResizeCoordinator, visible: Bool = true, gate: TerminalTargetGate? = nil,
         creatingInput: CreatingTerminalInput? = nil,
         burstTrace: BurstTrace? = nil, policyBlocked: @escaping @Sendable () -> Bool = { false },
         endpoint: @escaping @Sendable () async throws -> DaemonEndpoint) {
        self.resizes = resizes
        probeSurface = target.attachment.surface.rawValue
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.terminal")
        let surface = target.attachment.surface.rawValue
        let driver = TerminalAttachDriver<TerminalAttachment>(
            initialSize: target.initialSize,
            visible: visible,
            // A view with no gate attaches to a terminal that already runs: a restore.
            restoring: gate == nil,
            opener: { size in
                var attachment = target.attachment
                if let gate {
                    guard let resolved = await gate.value() else { throw CancellationError() }
                    attachment = resolved
                }
                #if DEBUG
                try await DebugSlowAttach.shared.beforeAttach(surface: String(surface))
                #endif
                return try await TerminalAttachment.attach(endpoint: try await endpoint(), target: attachment,
                                                    size: size, claimGeometry: false,
                                                    snapshotVersion: Self.attachSnapshotVersion,
                                                    localHistory: Self.attachLocalHistory,
                                                    images: Self.attachImages,
                                                    device: await Self.sizingDevice.value)
            },
            onFailure: { error in
                logger.error("attach \(surface) failed: \(String(describing: error), privacy: .public)")
            },
            onReattach: { attempt in
                logger.info("terminal \(surface) fell behind; reattaching for a fresh replay (open \(attempt))")
            },
            observer: InputJournal.shared.isEnabled ? InputJournal.attachObserver(surface: String(surface)) : nil,
            cursorDefault: target.cursorDefault,
            backoffDelay: { failed in try await Self.reattachBackoff(afterFailures: failed); if policyBlocked() { throw CancellationError() } },
            // Marked where the grid really goes to the PTY: the machine sends nothing for a resize
            // without a live link, while hidden, or of the size it already holds.
            onGridSent: burstTrace.map { trace -> TerminalAttachDriver<TerminalAttachment>.GridSent in
                { size, expectsEcho in
                    guard trace.isArmed else { return }
                    trace.gridSent(surface: surface, cols: size.cols, rows: size.rows, expectsEcho: expectsEcho)
                }
            }
        )
        self.driver = driver
        self.creatingInput = creatingInput
        self.burstTrace = burstTrace
        events = AsyncStream(unfolding: {
            await driver.nextStep().map { step in
                let event = Self.event(for: step)
                if let burstTrace, burstTrace.isArmed {
                    switch event {
                    case .output: burstTrace.output(surface: surface)
                    // The daemon applied a grid: its first output after this is at that size.
                    case .resize(let cols, let rows): burstTrace.gridAnnounced(surface: surface, cols: cols, rows: rows)
                    default: break
                    }
                }
                switch event {
                case .status(.disconnected), .status(.restoring):
                    guard policyBlocked() else { return event }
                    return .status(.disconnected(.turnedOffByOrganization, reconnecting: false))
                default:
                    return event
                }
            }
        },
                             onCancel: { driver.cancelSteps() })
        driver.start()
        #if DEBUG || CMUX_BENCH_HOOKS
        // The view of a traced new terminal's tab: its session is matched by this IO.
        if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.watch(io: ObjectIdentifier(self), surface: surface) }
        #endif
    }

    deinit {
        driver.close()
    }

    // MARK: TerminalIO

    /// The daemon terminal by its surface id, as its attachment names it to the typing probe.
    nonisolated var typingProbeSource: TypingLatencyProbe.Source? { probeSurface == 0 ? nil : .terminal(probeSurface) }

    /// The daemon's VT core answers DA/DSR, so the surface mirrors only.
    var answersTerminalQueries: Bool { true }

    func write(_ data: Data) async {
        if let creatingInput, await creatingInput.write(data) { return }
        driver.input(data)
    }

    /// Focus takes geometry back after another client sized the terminal,
    /// or re-attaches a disconnected view.
    func focusGained() async {
        driver.focused()
    }

    /// Take over from the "Sized for" chip: always a new claim (see `TerminalAttachMachine`).
    func takeOverSize(setLatest: Bool) async {
        driver.takeOver(setLatest: setLatest)
    }

    /// A click in a disconnected view re-attaches it.
    func reconnectRequested() async {
        driver.reconnect()
    }

    /// The surface's local history did not match the host's: ask for a
    /// fresh READY + history.
    func resyncRequested() async {
        driver.requestResync()
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        guard cols > 0, rows > 0 else { return }
        let size = CellSize(cols: cols, rows: rows)
        await MainActor.run { resizes.submit(self, size: size) }
    }

    // MARK: App control

    /// Takes the view's grid in the caller's turn (`TerminalIO.resizeOnMain`): a final grid goes now
    /// (`ResizeCoordinator.submitFinal`), any other the next frame.
    @MainActor func resizeOnMain(cols: Int, rows: Int, final: Bool, window: NSWindow?) -> Bool {
        guard cols > 0, rows > 0 else { return true }
        let size = CellSize(cols: cols, rows: rows)
        if final {
            resizes.submitFinal(self, size: size, window: window)
        } else {
            resizes.submit(self, size: size, window: window)
        }
        return true
    }

    /// Called by `ResizeCoordinator` once the size settled.
    @MainActor func applySettled(_ size: CellSize) {
        driver.resize(size)
    }

    @MainActor var awaitsEcho: Bool { !driver.machine.echoesDue.isEmpty }

    /// A visible live view holds geometry until another client's grid is
    /// announced, and a resize it reports claims it back
    /// (`TerminalAttachMachine`), so the daemon applies and announces it.
    @MainActor func appliesViewGrid(reporting: Bool) -> Bool {
        let machine = driver.machine
        return machine.liveLink != nil && machine.visible && (reporting || machine.claimed)
    }

    /// Hidden views release canonical geometry so another client (or the
    /// next visible view) owns it; shown views claim it again.
    @MainActor func setVisible(_ visible: Bool) {
        driver.setVisible(visible)
    }

    /// The terminal or the daemon connection is back: a disconnected view
    /// re-attaches (one attempt; nothing happens otherwise).
    @MainActor func reconnect() {
        driver.reconnect()
    }

    /// The daemon reports the terminal's process ended: show the last screen
    /// with "Process exited" and never re-attach.
    @MainActor func processExited() {
        driver.processExited()
    }

    /// The daemon reports the terminal running again after a dead report:
    /// an exited view re-attaches.
    @MainActor func processRevived() {
        driver.processRevived()
    }

    /// Backoff before the `failed + 1`th re-attach in a row, 30 s after 8 doublings: spaces the view's own
    /// retries and the event-started ones after them. A view turned off by its organization stops after it (the caller).
    nonisolated static func reattachBackoff(afterFailures failed: Int) async throws {
        var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
        for _ in 1..<min(max(1, failed), 8) { _ = backoff.next() }
        // concurrency-allow: async sleep on the attach task, only before a re-attach that follows a failed one
        try await backoff.wait(owner: "terminal.reattach")
    }

    /// Ends the attachment (or cancels the attach in flight). The terminal
    /// keeps running in the daemon.
    @MainActor func close() {
        driver.close()
        resizes.cancel(self)
    }

    /// Attachment state for diagnostics and tests.
    var attachPhase: TerminalAttachDriver<TerminalAttachment>.Machine.Phase { driver.machine.phase }

    // MARK: Steps

    /// The GHOSTSNP version the surface restores (`terminal-snapshot-v1`);
    /// nil when the linked libghostty cannot restore snapshots.
    static let attachSnapshotVersion: UInt16? = TerminalSession.snapshotVersion == 0 ? nil : TerminalSession.snapshotVersion
    /// The surface restores local-history READYs (S2c).
    static let attachLocalHistory = TerminalSession.restoresLocalHistory
    /// The surface applies Kitty image replays (S3k).
    static let attachImages = TerminalSession.appliesKittyReplay

    static func event(for step: TerminalStreamPlan.Step) -> TerminalIOEvent {
        switch step {
        case .replay, .output, .snapshot: DebugTimings.markLaunch("first_terminal_content")
        default: break
        }
        return switch step {
        case .grid(let columns, let rows): .resize(cols: columns, rows: rows)
        case .replay(let replay): replayEvent(replay)
        case .snapshot(let frame): .snapshot(frame.data, phase: snapshotPhase(frame))
        case .output(let data): .output(data)
        case .exited: .exited
        case .status(let status): .status(Self.connection(status))
        case .sizing(let notice): .sizedFor(notice.map(Self.sizedFor))
        }
    }

    /// This Mac in the terminal's shared sizing: views name it, and their attach joins
    /// `shared-sizing-v1` (size states for "Sized for", and the Mac's name on other devices).
    /// Read once, off the main actor (MacName).
    static let sizingDevice = Task { TerminalSizingDevice(kind: "mac", name: await MacName().computerName()) }

    static func sizedFor(_ notice: TerminalSizeNotice) -> TerminalSizedFor {
        TerminalSizedFor(deviceName: notice.ownerName, deviceKind: notice.ownerKind, sameDevice: notice.sameDevice,
                         grid: TerminalGridSize(columns: notice.cols, rows: notice.rows),
                         fixedSize: notice.fixedSize, takeOverSetsLatest: notice.takeOverSetsLatest)
    }

    static func connection(_ status: TerminalLinkStatus) -> TerminalConnectionStatus {
        switch status {
        case .connected: .connected
        case .restoring: .restoring
        case .exited: .exited
        case .disconnected(let reason, let reconnecting): .disconnected(cause(reason), reconnecting: reconnecting)
        }
    }

    private static func cause(_ reason: TerminalDisconnectReason) -> TerminalDisconnectCause {
        switch reason {
        case .streamEnded: .streamEnded
        case .connectionLost: .connectionLost
        case .attachFailed: .attachFailed
        case .fellBehind: .fellBehind
        }
    }

    private static func snapshotPhase(_ frame: TerminalSnapshotFrame) -> TerminalSnapshotPhase {
        if frame.phase == .images { return .images(skipped: frame.skippedImages ?? 0) }
        guard frame.phase == .ready else { return .history }
        guard let check = frame.localHistory, let cols = frame.cols, let rows = frame.rows else { return .ready }
        return .readyLocalHistory(TerminalLocalHistory(columns: cols, rows: rows, historyRows: check.rows, digest: check.digest))
    }

    /// A replay with usable Kitty graphics state restores it; otherwise the
    /// plain VT bytes replay (ghostty.h requires nonzero image-id cursors).
    static func replayEvent(_ replay: TerminalReplay) -> TerminalIOEvent {
        guard let kitty = replay.kittyGraphicsState,
              kitty.primaryReplayNextImageID != 0, kitty.alternateReplayNextImageID != 0,
              kitty.primaryNextImageID != 0, kitty.alternateNextImageID != 0
        else { return .replay(replay.data) }
        return .kittyReplay(TerminalKittyReplay(
            vt: replay.data,
            cursorOffset: kitty.replayCursorOffset,
            limits: .init(imageBytes: kitty.imageBytes, inflightBytes: kitty.inflightBytes,
                          images: kitty.images, placements: kitty.placements),
            replayCursors: .init(primary: kitty.primaryReplayNextImageID, alternate: kitty.alternateReplayNextImageID),
            nextCursors: .init(primary: kitty.primaryNextImageID, alternate: kitty.alternateNextImageID),
            aliases: replay.kittyImageAliases.map { .init(imageID: $0.imageID, imageNumber: $0.imageNumber) }
        ))
    }
}

extension DaemonTerminalIO: ResizeTarget {}
