import AppKit
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextInputModel
import CmuxNextTerminal
import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import os

/// Bridges one daemon terminal attachment (`TerminalAttachment`) to a
/// Ghostty surface (`TerminalIO`).
///
/// The attachment lifecycle is one `TerminalAttachMachine` run by a
/// `TerminalAttachDriver` (state-audit.md T1, T3-T5):
/// - Attaches on its machine's connection (`TerminalAttachment.attach(on:)`) without claiming geometry, so showing a
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
    /// The session's input lane drains here (``inputDrain()``), and each attach link's socket writer targets it.
    private let inputQueue: DispatchQueue
    private let creatingInput: CreatingTerminalInput?
    /// The burst marks of grid echoes and first outputs (nil: none), in every build while a recording runs.
    private let burstTrace: BurstTrace?
    /// The daemon surface whose marks this view writes.
    private let surface: UInt64
    /// The app's grid sender (`AppServices.resizes`): next frame, one in flight, a final grid now.
    private let resizes: ResizeCoordinator
    /// Told after each step this view maps, and each live chunk its lane takes (nil in Release).
    private let screenChanged: (@Sendable () -> Void)?
    /// The id of the terminal still being created whose keys go to the daemon by id, nil otherwise.
    var creatingTerminalID: String? { creatingInput?.terminalID }

    /// - Parameter policyBlocked: true while an administrator turned off the
    ///   feature that reaches this terminal's machine: every disconnect shows
    ///   "Turned off by your organization" and the endpoint refuses re-attaches.
    /// `gate`: the view of a terminal not created yet attaches only once the gate names it.
    /// `createIntent`: the `create.tab` intent id of the new tab this view shows (0: none, a restore): its first
    /// attach writes that create's stages (`NewTerminalTrace.FirstAttach`).
    /// `burstTrace`: where the grids this view sends, their echoes and its first output after each echo
    /// go while a recording runs (`debug.burst`, or a trace recording's `burst` category).
    /// `resizes`: the app's grid sender (``ResizeCoordinator``), from its composition root.
    /// `hangWatch`: watches each line the attachment's reader handles (`DaemonService.hangWatch`).
    /// `screenChanged`: told after each step this view maps (output, replay, grid, link status), so the oracle's
    /// `terminals` facet waits wake (`AppServices.terminalScreenChanged`; nil in Release).
    /// `keyStamps`: takes the daemon's stages of each key echo; only for a daemon on this Mac, whose
    /// clock they are on.
    /// `connection`: the machine connection each attach streams on, or reaches its endpoint from.
    /// `streamFocus`: the app's one focused terminal view, whose stream rides the input lane.
    init(target: Target, resizes: ResizeCoordinator, visible: Bool = true, gate: TerminalTargetGate? = nil,
         createIntent: UInt64 = 0, creatingInput: CreatingTerminalInput? = nil,
         burstTrace: BurstTrace? = nil, policyBlocked: @escaping @Sendable () -> Bool = { false },
         hangWatch: (any HangWatchScoping)? = nil, screenChanged: (@Sendable () -> Void)? = nil,
         keyStamps: (any TerminalKeyStampSink)? = nil,
         streamFocus: TerminalStreamFocus? = nil,
         connection: @escaping @Sendable () async throws -> DaemonConnection) {
        self.resizes = resizes
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.terminal")
        let surface = target.attachment.surface.rawValue
        let firstAttach = NewTerminalTrace.FirstAttach(intent: createIntent)
        // qos-allow: key echo path: a typed key goes to the attach socket on this queue and its frame waits for the echo
        let inputQueue = DispatchQueue(label: "com.cmuxterm.next.terminal.attach-input", qos: .userInteractive)
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
                return try await TerminalAttachment.attach(on: try await connection(), target: attachment,
                                                    size: size, claimGeometry: false,
                                                    snapshotVersion: Self.attachSnapshotVersion,
                                                    localHistory: Self.attachLocalHistory,
                                                    images: Self.attachImages,
                                                    device: await Self.sizingDevice.value,
                                                    hangs: hangWatch, createIntent: firstAttach.take(),
                                                    inputQueue: inputQueue, keyStamps: keyStamps)
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
                    trace.gridSent(surface: surface, cols: size.cols, rows: size.rows, expectsEcho: expectsEcho)
                }
            },
            streamFocus: streamFocus
        )
        self.driver = driver
        self.inputQueue = inputQueue
        self.creatingInput = creatingInput
        self.burstTrace = burstTrace
        self.surface = surface
        self.screenChanged = screenChanged
        events = AsyncStream(unfolding: {
            await driver.nextStep().map { step in
                let event = Self.event(for: step)
                screenChanged?()
                // Each mark checks for a recording itself; with none, it drops an ended one's echo matching.
                if let burstTrace {
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
        burstTrace?.forget(surface: surface)
    }

    // MARK: TerminalIO

    /// The daemon's VT core answers DA/DSR, so the surface mirrors only.
    var answersTerminalQueries: Bool { true }

    func write(_ data: Data) async {
        if let creatingInput, await creatingInput.write(data) { return }
        driver.input(data)
    }

    /// The session's input drains on the attach input queue, which the attach socket's writer targets: a key
    /// is reduced and written to the socket there, one thread hop from the main thread.
    func inputDrain() -> TerminalInputDrain {
        Self.inputDrain(on: inputQueue, driver: driver, creating: creatingInput, sentByID: Self.journalByID(surface: surface))
    }

    /// Bytes sent by terminal id reach the PTY without passing the attachment: the input journal counts them as
    /// that terminal's input too, as the attachment's own observer does (its byte counts judge where keys went).
    private static func journalByID(surface: UInt64) -> (@Sendable (Int) -> Void)? {
        guard InputJournal.shared.isEnabled else { return nil }
        return { count in
            var record = InputJournalEntry.Attach(surface: String(surface), event: "input", phase: "creating", droppedBytes: 0)
            record.bytes = count
            InputJournal.shared.append(window: nil, .attach(record))
        }
    }

    /// Hands every lane record to `driver` on `queue`. The driver reduces a key and appends it to the socket's
    /// outbox in the lane's turn, and the socket writer, which targets `queue`, sends it on that serial queue
    /// right after: one thread hop from the main thread to `write(2)`, as Chromium posts input once to the IO
    /// thread that owns the IPC channel (ipc/ipc_channel_proxy.cc, `ChannelProxy::Send`).
    ///
    /// While the terminal is still being created its bytes go by id, one awaited send at a time; the lane holds
    /// every later record meanwhile, and a chunk the daemon refused goes by the attachment on `queue` before the
    /// lane resumes, so no record passes it. A key's bytes carry its latency slot's flow to the link;
    /// by id they go without it.
    static func inputDrain<Link: TerminalAttachLink>(on queue: DispatchQueue, driver: TerminalAttachDriver<Link>,
                                                     creating: (any CreatingTerminalInputSending)?,
                                                     sentByID: (@Sendable (Int) -> Void)? = nil) -> TerminalInputDrain {
        TerminalInputDrain(queue: queue) { record, resume in
            switch record {
            case .bytes(let data), .keyBytes(let data, _):
                guard let creating, !creating.sendsByAttachment else {
                    driver.input(data, keyFlow: record.keyFlow)
                    return .next
                }
                // The drain's closure is nonisolated: the send never touches the main thread.
                Task { @concurrent in
                    let byID = await creating.write(data)
                    queue.async {
                        if byID { sentByID?(data.count) } else { driver.input(data) }
                        resume()
                    }
                }
                return .hold
            case .resize: break // never sent: `resizeOnMain` takes every grid
            case .focusGained: driver.focused()
            case .takeOverSize(let setLatest): driver.takeOver(setLatest: setLatest)
            case .reconnect: driver.reconnect()
            case .resync: driver.requestResync()
            }
            return .next
        }
    }

    /// Live output goes from the attach link's reader thread straight to `lane` (``TerminalAttachDriver/setOutputSink(_:)``),
    /// with the marks the stream's output step makes: the burst trace's first output and the oracle's screen change.
    func setOutputLane(_ lane: TerminalEchoLane?) {
        driver.setOutputSink(lane.map { lane in
            TerminalEchoSink { [burstTrace, surface, screenChanged] data, flow, wake in
                burstTrace?.output(surface: surface)
                let full = lane.enqueue(data, flow: flow, wake: wake)
                screenChanged?()
                return full
            }
        })
    }

    /// Focus takes geometry back after another client sized the terminal,
    /// or re-attaches a disconnected view.
    func focusGained() async {
        driver.focused()
    }

    /// The view's stream takes the input lane from the view that had it, in the main thread's focus order
    /// (each view drains its ordered input on a queue of its own, so their `focusGained` can run out of order).
    @MainActor func streamFocusGained() {
        driver.takeStreamFocus()
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

    /// Never sent: ``resizeOnMain(cols:rows:final:window:)`` takes every grid in the caller's turn (it always
    /// returns true), so the session sends no grid through its ordered stream (`TerminalSession.surfaceDidReport`).
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}

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
    /// next visible view) owns it; shown views claim it again. The view's stream follows: a hidden one gets
    /// no output until it shows (`set-stream-priority`, TabContentCache's reveal and conceal).
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

    /// This view's live output per stage, daemon to surface (`debug.surfaces`): the live link's and the lane's.
    func streamReport(_ surface: TerminalSurfaceDiagnostics) -> TerminalStreamReport {
        TerminalStreamReport(ledger: driver.machine.liveLink?.link.streamLedger,
                             lane: surface.laneOutput.map { ($0.queued, $0.parsed, $0.skipped) },
                             readerFeedsViewLane: surface.readerFeedsViewLane)
    }

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
        case .inputEcho(let flow): .inputEcho(flow: flow)
        case .outputResume(let marker): .outputResume(TerminalOutputResume { marker.resume() })
        case .exited: .exited
        case .status(let status): .status(Self.connection(status))
        case .sizing(let notice): .sizedFor(notice.map(Self.sizedFor))
        }
    }

    /// This Mac in the terminal's shared sizing: views name it, and their attach joins
    /// `shared-sizing-v1` (size states for "Sized for", and the Mac's name on other devices).
    /// Read once, off the main actor (MacName).
    static let sizingDevice = Task { @concurrent in TerminalSizingDevice(kind: "mac", name: await MacName().computerName()) }

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
