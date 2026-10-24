import CmuxMobileModel
import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "terminal")

/// A terminal tab on the Mac, attached over its own `daemon` channel
/// (cmux-tui protocol, `cmux-tui/spec/commands.md` and `events.md`):
///
/// - `attach-surface {surface}` (bytes mode). The `vt-state` replay and the
///   live `output` chunks are fed to the local Ghostty mirror in order; a
///   `resized` event (protocol 6+) resets the mirror (`ESC c`) and replays.
///   `detached` ends the session.
/// - Input: `send {surface, bytes}` (base64), in order, one per main-queue
///   turn and batched while one is being written, several unanswered at
///   once (``drainInput()``), on its own `daemon` channel on the link's input lane
///   (PROTOCOL.md "Lanes"), so a keystroke or ^C never waits behind the
///   output it should interrupt. Until that channel is open (or when it
///   fails) input goes on the attach channel.
/// - Size: `resize-surface {surface, cols, rows}` with the phone's TUI grid,
///   on the attach channel (the daemon gives geometry authority to the
///   attaching client), only while the terminal is on screen
///   (``setClaimsSize(_:)``). Hidden, it sends `release-surface-size` and no
///   size until it is shown again; stopped, it releases before the channel
///   closes; while it claims, it refreshes the Mac's size lease
///   (`size-lease-v1`) every ``sizeLeaseRefresh`` (PROTOCOL.md, "Terminal
///   size claims").
///
/// - Shared sizing (`shared-sizing-v1`, PROTOCOL.md "Terminal sizing
///   policy"): the attach reply and `size-state` events feed ``sizing``, the
///   terminal's live size state (who is connected, the size each one asks
///   for, who sets the grid). Typing, pasting or tapping the terminal sends
///   `note-size-activity` (at most once a second, only while this view does
///   not set the grid), so the Mac's "Prefer the Active Device" can pick the
///   phone: keystrokes go on the input lane, another connection, and never
///   count as this view's activity by themselves.
///
/// The alternate screen flag is derived from the bytes (no event carries it).
///
/// A channel that ends without `detached` is a dropped link (background,
/// transport switch, Mac restart), not the end of the terminal: the session
/// waits, and ``reconnect()`` (the coordinator calls it on every new link)
/// attaches again, resetting the mirror before the replay and restoring the
/// size.
@MainActor
public final class DaemonTerminalSession: TerminalSession {
    /// The daemon surface the terminal is on. A daemon that restarted
    /// (crash, update) numbers its surfaces again; a reattach follows the
    /// terminal by ``terminalID`` (`resolve-terminal`).
    public private(set) var surface: Int
    /// The Mac terminal's durable id (`terminal_id`, `term_…`), when known.
    public let terminalID: String?
    public private(set) var programName: String
    public private(set) var isAlternateScreen = false
    /// The Mac terminal's rows (`vt-state`, `resized`), else the size asked for.
    public var remoteRows: Int? { reportedRows ?? lastSize?.rows ?? 24 }
    private var reportedRows: Int?
    /// The Mac's grid changed since the screen was last told (``TerminalSessionEvent/hostGrid(columns:rows:)``).
    private var hostGridChanged = false
    /// The Mac terminal's columns (`vt-state`, `resized`); nil before the
    /// first attach. The screen renders this grid when it is not the phone's.
    public var remoteColumns: Int? { reportedColumns }
    /// The owner the screen was last told (``TerminalSessionEvent/hostGridOwner(_:)``).
    private var toldHostGridOwner: String??

    /// Tells the screen when the device that sets the grid changed.
    private func noteHostGridOwner() {
        let name = hostGridOwnerName
        guard toldHostGridOwner != .some(name) else { return }
        toldHostGridOwner = .some(name)
        handler?(.hostGridOwner(name))
    }

    /// The device that sets the Mac's grid, when it is not this phone.
    public var hostGridOwnerName: String? {
        guard let state = sizing.state, !sizing.selfIsOwner, let owner = state.owners.first,
              let row = state.participants.first(where: { $0.id == owner }) else { return nil }
        return row.deviceName ?? row.displayName
    }
    /// The last attach or send failure (shown nowhere yet; logged).
    public private(set) var lastError: String?
    /// The terminal's shared size state, live while attached to a daemon
    /// with `shared-sizing-v1`.
    public let sizing = TerminalSizingLive()
    /// The daemon takes `note-size-activity` (it listed `shared-sizing-v1`).
    private var sharedSizing = false
    /// When the last `note-size-activity` went out (``now``'s clock).
    private var lastActivityNote: TimeInterval?
    /// At most one activity note per this many seconds.
    static let activityNoteInterval: TimeInterval = 1

    private let open: @Sendable () async throws -> DaemonClient
    private let clientInfo: [String: String]
    private let openInput: (@Sendable () async throws -> DaemonClient)?
    private var client: DaemonClient?
    /// The input-lane channel for `send`, once open.
    private var inputClient: DaemonClient?
    /// Keystrokes not yet sent, with when they were typed; sent as one
    /// `send` (``drainInput()``). Keys older than `inputHoldLimit` when the
    /// terminal can take them are dropped, never sent late (termfix-r13 D5:
    /// a command typed during an outage ran 15.4 minutes later).
    private var input: [(bytes: Data, at: TimeInterval, detached: Bool)] = []
    /// Keys queued while detached expired: everything typed until the next
    /// attach is refused, so no fragment of a command (its last 2 s) can
    /// reach the shell after the rest was dropped (r13 review).
    private var refusingInput = false
    /// How long typed keys may wait for the terminal (a blip) before they
    /// are dropped and the screen is told (seconds).
    public static let inputHoldLimit: TimeInterval = 2
    /// The clock the hold is measured on (tests inject one).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// A `send` is being written (writes go one after another, in order).
    private var inputWriting = false
    /// Sends written and not yet answered, all on `inputTarget`.
    private var inputInFlight = 0
    private var inputTarget: DaemonClient?
    /// A send failed: no new one until the others on its channel settle.
    private var inputRecovering = false
    /// The input lane given up because a `send` got no answer: its other
    /// unanswered sends are not sent again either.
    private var abandonedInputLane: DaemonClient?
    /// Unanswered sends allowed at once: about a second of scroll frames, so
    /// a lost reply does not stop input (later sends keep both directions
    /// moving, and the loss is repaired by duplicate ACKs).
    static let maxInputInFlight = 64
    /// How long a `send` may go unanswered before ``armTailProbe()`` writes
    /// `ping`s behind it: many round trips, well under the 1 s RTO.
    var tailProbeDelay: Duration = .milliseconds(150)
    /// Writes and answers so far: a probe fires only if none came since it was armed.
    private var inputProgress = 0
    private var tailProbe: Task<Void, Never>?
    /// When each unanswered send went out, by batch number.
    private var inputWrittenAt: [Int: TimeInterval] = [:]
    /// No new send while the oldest unanswered one is older than this
    /// (seconds): a stalled link holds typed keys in `input`, where the hold
    /// rules apply, instead of writing up to `maxInputInFlight` of them to
    /// arrive late. Scrolling keeps many in flight; a stall does not.
    var inputStallLimit: TimeInterval = 0.5
    /// Sends written and not yet answered (tests).
    var inputsInFlight: Int { inputInFlight }
    /// A tail probe is armed (tests).
    var tailProbeArmed: Bool { tailProbe != nil }
    private var nextInputBatch = 0
    /// Batches of the failed channel, held until its sends all settle.
    private var inputFailed: [(number: Int, bytes: Data, at: TimeInterval, written: Bool)] = []
    private var inputDrainScheduled = false
    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
    /// Decodes lines given to `handle(_:)` (the attach stream has its own, off the main actor).
    private var lineParser: DaemonTerminalEventParser
    private var inbox: DaemonTerminalInbox?
    private var outputPaused = false
    private var eventTask: Task<Void, Never>?
    /// Resizes go out one at a time, in order, on the attach channel.
    private var outbox: [Outgoing] = []

    private enum Outgoing: Sendable {
        case size(columns: Int, rows: Int)
        /// `release-surface-size`: the terminal left the screen.
        case release
    }

    /// Whether this phone's size should count on the Mac now (the terminal
    /// is on screen in the foreground app). Set by ``setClaimsSize(_:)``.
    private var claimsSize = true
    /// The Mac holds a size of this session's now (a sized attach or a
    /// `resize-surface` went out, and no release after it).
    private var sizeClaimed = false
    /// The daemon lists `size-lease-v1`: a claim lasts only while refreshed.
    private var leased = false
    /// How often a claimed size is sent again while the daemon leases it.
    /// The daemon's lease is 45 s.
    var sizeLeaseRefresh: Duration = .seconds(15)
    private var leaseTask: Task<Void, Never>?
    private var draining = false
    private var pendingSize: (columns: Int, rows: Int)?
    /// The grid last asked for, put back after a reattach.
    private var lastSize: (columns: Int, rows: Int)?
    private var attached = false
    private var attaching = false
    /// The daemon said the surface is gone (`detached`): never reattach.
    private var ended = false
    /// Attached to the surface now.
    public var isAttached: Bool { attached }
    /// Has been attached once (a later attach is a reattach).
    private var everAttached = false
    /// The Mac's name, for the connecting placeholder.
    public var macName: String?

    /// `connecting` until the first attach, `reattaching` after a dropped
    /// link, `offline` while the Mac is gone (`setMacOffline`), `attached`
    /// while the screen mirrors the Mac's terminal.
    public var connectionState: TerminalConnectionState {
        // An ended terminal shows its last screen, not a spinner; a Mac that is
        // gone says so; a reattach that gave up (its line says to type to try
        // again) shows its last screen too.
        if attached || ended { return .attached }
        if macOffline { return .offline(mac: macName) }
        if gaveUp { return .attached }
        return everAttached ? .reattaching(mac: macName) : .connecting(mac: macName)
    }

    /// The coordinator's word on the Mac (`LinkMachine.Phase.showsTerminalsOffline`).
    private var macOffline = false

    /// The Mac is offline or out of reach (true), or back (false). A
    /// detached session then says so instead of "Reattaching…" forever
    /// (termfix-r13 D4, T-LIFE-13); an attached one is unaffected.
    public func setMacOffline(_ offline: Bool) {
        guard offline != macOffline else { return }
        let before = connectionState
        macOffline = offline
        let after = connectionState
        if after != before, handler != nil, !ended { handler?(.connection(after)) }
        if offline { expireInput() }
    }

    /// `open` returns a client on a fresh `daemon` channel to the Mac;
    /// `openInput`, one on the link's input lane for keystrokes (nil: input
    /// shares the attach channel).
    /// `clientInfo`: `set-client-info` for the attach channel, sent with
    /// `identify` before each attach. With `device_kind` a phone or tablet,
    /// the Mac's daemon keeps the grid for a while after this phone's link
    /// drops, so a reattach finds it unchanged: the PTY is not resized away
    /// and back, and Codex does not rebuild (and truncate) its scrollback
    /// (termqa V2-5).
    public init(
        surface: Int,
        terminalID: String? = nil,
        programName: String = "zsh",
        clientInfo: [String: String] = [:],
        open: @escaping @Sendable () async throws -> DaemonClient,
        openInput: (@Sendable () async throws -> DaemonClient)? = nil
    ) {
        self.surface = surface
        self.terminalID = terminalID
        lineParser = DaemonTerminalEventParser(surface: surface)
        self.programName = programName
        self.clientInfo = clientInfo
        self.open = open
        self.openInput = openInput
    }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        guard self.handler == nil else { return }
        self.handler = handler
        handler(.connection(connectionState))
        Task { await attach() }
    }

    public func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        // A reattach that gave up: typing tries again (the line it printed says so).
        if gaveUp { reconnect() }
        if refusingInput, !attached {
            log.notice("surface \(self.surface, privacy: .public): \(bytes.count, privacy: .public) typed bytes refused (earlier keys were already dropped)")
            handler?(.inputNotSent(bytes: bytes.count))
            return
        }
        input.append((bytes, now(), !attached))
        if attached {
            scheduleInputDrain()
            noteInteraction()
        } else {
            // Dropped once they are too old to send, not at the reattach:
            // the screen says so while the person still remembers typing.
            let limit = Self.inputHoldLimit
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(limit))
                self?.expireInput()
            }
        }
    }

    /// The terminal is unreachable: every key still queued now waits for a
    /// detached terminal, from when it was typed.
    private func markInputDetached() {
        input = input.map { ($0.bytes, $0.at, true) }
        guard !input.isEmpty else { return }
        let limit = Self.inputHoldLimit
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            self?.expireInput()
        }
    }

    /// Keys that waited for a detached terminal longer than
    /// `inputHoldLimit`: all queued keys are dropped (never only the oldest:
    /// the rest of a command must not run alone), input is refused until the
    /// next attach, and the screen is told. Keys typed while attached (a
    /// slow but live link) never expire here.
    private func expireInput() {
        let cutoff = now() - Self.inputHoldLimit
        guard input.contains(where: { $0.detached && $0.at <= cutoff }) else { return }
        let bytes = input.reduce(0) { $0 + $1.bytes.count }
        input.removeAll()
        if !attached { refusingInput = true }
        log.notice("surface \(self.surface, privacy: .public): \(bytes, privacy: .public) typed bytes dropped (the terminal was unreachable for longer than \(Self.inputHoldLimit, privacy: .public) s)")
        handler?(.inputNotSent(bytes: bytes))
    }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        // Hidden: remembered for when the terminal is shown, never sent
        // (it would make the Mac's pane the phone's size again).
        guard claimsSize else {
            lastSize = (columns, rows)
            pendingSize = (columns, rows)
            return
        }
        // A no-op resize never reaches the Mac (each one makes it reset the
        // mirror and replay, and an inline TUI redraw its whole transcript).
        if attached, let last = lastSize, last.columns == columns, last.rows == rows { return }
        log.notice("surface \(self.surface, privacy: .public): resize to \(columns, privacy: .public)x\(rows, privacy: .public)")
        lastSize = (columns, rows)
        if attached {
            enqueue(.size(columns: columns, rows: rows))
        } else {
            pendingSize = (columns, rows)
        }
    }

    /// The terminal is on screen in the foreground app (true), or it left
    /// (false: another tab, the grid, a sheet over it, the app in the
    /// background). Leaving releases the phone's size on the Mac at once, so
    /// the Mac's pane gets its own size back; coming back claims the last
    /// size again.
    public func setClaimsSize(_ claims: Bool) {
        guard claims != claimsSize else { return }
        claimsSize = claims
        outbox.removeAll { if case .size = $0 { true } else { false } }
        if claims {
            if attached, let size = lastSize {
                log.notice("surface \(self.surface, privacy: .public): shown again, claiming \(size.columns, privacy: .public)x\(size.rows, privacy: .public)")
                enqueue(.size(columns: size.columns, rows: size.rows))
            }
        } else {
            stopLeaseRefresh()
            if attached, sizeClaimed {
                log.notice("surface \(self.surface, privacy: .public): left the screen, releasing its size")
                enqueue(.release)
            }
            sizeClaimed = false
        }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        inbox?.close()
        inbox = nil
        outputPaused = false
        handler = nil
        stopLeaseRefresh()
        // The Mac drops this attach (a tab cooled out of the warm set, or
        // gone). The size is released first and answered, so the Mac never
        // reads the close as a dropped link (which holds its grid for 30 s).
        if let client {
            // A claimed size, or a release still waiting behind another request.
            let release = attached && (sizeClaimed || outbox.contains { if case .release = $0 { true } else { false } })
            let surface = surface
            Task {
                if release {
                    _ = try? await Self.within(.seconds(2)) {
                        try await client.request("release-surface-size", params: ["surface": surface])
                    }
                }
                await client.close()
            }
        }
        sizeClaimed = false
        attached = false
        client = nil
        dropInputLane()
        outbox.removeAll()
        input.removeAll()
        tailProbe?.cancel()
        tailProbe = nil
    }

    /// Attaches again after a dropped link. A no-op while attached or
    /// attaching, before `start`, and after the surface ended.
    public func reconnect() {
        guard handler != nil, !attached, !attaching, !ended else { return }
        if gaveUp {
            // A fresh round of retries, from the shortest delay.
            gaveUp = false
            attachRetries = 0
        }
        Task { await attach() }
    }

    /// Where the terminal is now, asked by its durable id before a reattach.
    enum Resolved: Equatable {
        case surface(Int)
        /// The Mac has no such terminal (closed).
        case gone
        /// The terminal's process exited (or it was tombstoned) while no
        /// surface shows it: say so at once instead of retrying (PR #22555 review).
        case exited(code: Int?)
        /// Known but on no surface yet (a daemon still adopting its terminal
        /// hosts after a restart): try again later.
        case notYet
        /// The daemon cannot say (an older one): attach by number.
        case unknown
    }

    static func resolved(_ reply: Data) -> Resolved {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return .unknown }
        if object["ok"] as? Bool == false || object["error"] != nil {
            let error = (object["error"] as? String) ?? ""
            return error.contains("terminal_not_found") ? .gone : .unknown
        }
        let data = object["data"] as? [String: Any] ?? object
        if let surface = data["surface"] as? Int { return .surface(surface) }
        if let lifecycle = data["lifecycle"] as? String, lifecycle == "exited" || lifecycle == "tombstoned" {
            return .exited(code: (data["exit"] as? [String: Any])?["code"] as? Int)
        }
        return data.keys.contains("surface") ? .notYet : .unknown
    }

    /// The terminal is no longer on the Mac: say so and stop, never wait
    /// "Reattaching…" forever.
    private func terminalGone(exitCode: Int? = nil, exited: Bool = false) {
        guard handler != nil, !ended else { return }
        ended = true
        attached = false
        log.notice("surface \(self.surface, privacy: .public): terminal \(self.terminalID ?? "-", privacy: .public) is no longer on the Mac (exited=\(exited, privacy: .public))")
        if let client { self.client = nil; Task { await client.close() } }
        let line = exited
            ? "[The terminal's process exited\(exitCode.map { " (code \($0))" } ?? "")]"
            : "[This terminal is no longer open on the Mac]"
        emitText("\r\n\u{1B}[2m\(line)\u{1B}[0m\r\n")
        handler?(.connection(.attached))
        handler?(.exited(code: Int32(clamping: exitCode ?? 0)))
    }

    // MARK: Shared sizing

    /// The person typed, pasted or tapped the terminal: tells the Mac this
    /// view is the active one (`note-size-activity`), at most once per
    /// ``activityNoteInterval`` and only while it does not set the grid
    /// already. A no-op against a daemon without shared sizing.
    public func noteInteraction() {
        guard attached, sharedSizing, claimsSize, let client, !sizing.selfIsOwner else { return }
        let at = now()
        if let last = lastActivityNote, at - last < Self.activityNoteInterval { return }
        lastActivityNote = at
        let surface = surface
        Task {
            if let reply = try? await client.request("note-size-activity", params: ["surface": surface]),
               let error = Self.error(in: reply) {
                log.error("note-size-activity failed: \(error, privacy: .public)")
            }
        }
    }

    /// The size state and own participant of an attach reply (shared sizing).
    nonisolated static func attachSizing(_ reply: Data) -> (TerminalSizeState?, String?) {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return (nil, nil) }
        return (TerminalSizeState.decode(data["size_state"]), data["participant"] as? String)
    }

    // MARK: Attach

    private func attach() async {
        guard !attaching else { return }
        attaching = true
        defer { attaching = false }
        do {
            let client = try await open()
            guard handler != nil else { return }
            self.client = client
            await client.start()
            // A reattach (or a retry) first asks where the terminal is: a Mac
            // daemon that restarted numbers its surfaces again, and the old
            // number may now name another terminal (defect 2 of
            // verify/transport-verify-20261019.md).
            if let terminalID, everAttached || attachRetries > 0 {
                let reply = try await client.request("resolve-terminal", params: ["terminal_id": terminalID])
                guard self.client === client else { return }
                switch Self.resolved(reply) {
                case .surface(let moved) where moved != surface:
                    log.notice("surface \(self.surface, privacy: .public): terminal \(terminalID, privacy: .public) is now surface \(moved, privacy: .public)")
                    surface = moved
                    lineParser = DaemonTerminalEventParser(surface: moved)
                case .exited(let code):
                    terminalGone(exitCode: code, exited: true)
                    return
                case .gone where attachRetries + 1 >= reattachBackoff.count:
                    terminalGone()
                    return
                case .gone:
                    // Right after the Mac app or its daemon restarts, a terminal
                    // can be missing from the registry for a moment: only a
                    // terminal still missing after the retries is gone.
                    throw LinkError(code: "attach", message: "terminal_not_found")
                case .notYet:
                    // Into the reattach backoff, keeping the last frame.
                    throw LinkError(code: "attach", message: "the terminal is not on a surface yet")
                case .surface, .unknown:
                    break
                }
            }
            let events = client.events
            eventTask?.cancel()
            inbox?.close()
            // Event lines are decoded off the main actor and reach it in
            // batches, one main-queue hop per batch (DaemonTerminalInbox).
            let inbox = DaemonTerminalInbox { [weak self] batch in
                MainActor.assumeIsolated {
                    guard let self, self.client === client else { return }
                    // Until the Mac confirms the attach, its events wait: the
                    // mirror is reset only for an attach that succeeded.
                    if self.heldEvents != nil {
                        self.heldEvents?.append(contentsOf: batch)
                        return
                    }
                    for event in batch { self.apply(event) }
                }
            }
            inbox.setPaused(outputPaused)
            self.inbox = inbox
            let surface = surface
            eventTask = Task.detached { [weak self] in
                var parser = DaemonTerminalEventParser(surface: surface)
                for await line in events {
                    await inbox.push(parser.parse(line))
                }
                // After the batches already queued (the main queue is FIFO).
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.channelEnded(client) }
                }
            }
            attachedWithSize = nil
            sizeClaimed = false
            // One write: the client info (it opts into the size lease) and identify.
            var info: [String: Any] = clientInfo
            info["capabilities"] = Self.clientCapabilities
            let setup = await client.requests(
                [(cmd: "set-client-info", params: info), (cmd: "identify", params: [:])]
            )
            let identify = try? setup.last?.get()
            // Hidden: attach without a size, so the attach claims none.
            let initialSize = claimsSize && (identify.map(Self.acceptsInitialSize) ?? false)
            leased = identify.map { Self.lists(Self.sizeLeaseCapability, $0) } ?? false
            sharedSizing = identify.map { Self.lists(Self.sharedSizingCapability, $0) } ?? false
            sizing.clear()
            lastActivityNote = nil
            // The mirror is not reset yet: a reattach that fails (a Mac host
            // that just restarted answers "unknown surface" for a moment) keeps
            // the last frame on screen under the reconnecting badge, instead
            // of a blank screen with an error line (termqa D3). The replay's
            // events wait in `heldEvents` until the attach is confirmed.
            heldEvents = []
            // With the size in the attach the Mac builds the replay at that size
            // once; attached first and resized after, it reset the mirror and
            // replayed the whole history a second time (user report 2026-10-14).
            var reply: Data
            if initialSize, everAttached, let size = lastSize ?? pendingSize, let overruled,
               overruled.asked.columns == size.columns, overruled.asked.rows == size.rows,
               overruled.mac.columns <= size.columns, overruled.mac.rows <= size.rows {
                // The Mac kept its own size for this request last time, and it
                // fits in this phone's grid: attach at that size (no PTY
                // resize), and do not ask again. A larger Mac grid is never
                // claimed: the phone renders into its own grid, so the daemon
                // must know the phone's real size (a wider PTY overprinted
                // and cut every row, 2026-10-23).
                log.notice("surface \(self.surface, privacy: .public): reattach at the Mac's \(overruled.mac.columns, privacy: .public)x\(overruled.mac.rows, privacy: .public) (asked \(size.columns, privacy: .public)x\(size.rows, privacy: .public) was overruled)")
                reply = try await client.request("attach-surface", params: ["surface": surface, "cols": overruled.mac.columns, "rows": overruled.mac.rows])
                if Self.error(in: reply) != nil {
                    reply = try await client.request("attach-surface", params: ["surface": surface])
                } else {
                    attachedWithSize = size
                }
            } else if initialSize, let size = lastSize ?? pendingSize {
                reply = try await client.request("attach-surface", params: ["surface": surface, "cols": size.columns, "rows": size.rows])
                if Self.error(in: reply) != nil {
                    // A policy that does not pass the size: attach without it.
                    reply = try await client.request("attach-surface", params: ["surface": surface])
                } else {
                    lastSize = size
                    attachedWithSize = size
                }
            } else {
                reply = try await client.request("attach-surface", params: ["surface": surface])
            }
            if let error = Self.error(in: reply) { throw LinkError(code: "attach", message: error) }
            guard self.client === client else { heldEvents = nil; return }
            let (sizeState, participant) = Self.attachSizing(reply)
            sizing.apply(sizeState, selfParticipant: participant)
            noteHostGridOwner()
            // The replay rebuilds the screen and scrollback. The reset also
            // tells the screen where the Mac's screen starts in its taller
            // mirror (TerminalRowShift).
            log.notice("surface \(self.surface, privacy: .public): mirror reset cause=\(self.everAttached ? "reattach" : "attach", privacy: .public) size=\(self.attachedWithSize.map { "\($0.columns)x\($0.rows)" } ?? "-", privacy: .public)")
            // The alternate screen is not touched here: the replay's
            // `vt-state` says its own final state before its rows (held or
            // still coming). Set to the primary screen first, a reattach to a
            // TUI left TUI mode and came back: the page showed the empty
            // primary screen with nothing held over it (termfix-r13 D2, `top`:
            // blank for ~170 ms, then half drawn).
            handler?(.output(Data("\u{1B}c".utf8)))
            let held = heldEvents ?? []
            heldEvents = nil
            for event in held { apply(event) }
            attachRetries = 0
            attached = true
            refusingInput = false
            everAttached = true
            handler?(.connection(.attached))
            lastError = nil
            pendingSize = nil
            outbox.removeAll { if case .release = $0 { true } else { false } }
            if attachedWithSize != nil { sizeClaimed = true }
            // Hidden while the attach was out: the size it carried goes back.
            if !claimsSize, sizeClaimed {
                outbox.insert(.release, at: 0)
                sizeClaimed = false
            }
            if claimsSize, let size = lastSize, attachedWithSize.map({ $0.columns != size.columns || $0.rows != size.rows }) ?? true {
                outbox.removeAll { if case .size = $0 { true } else { false } }
                outbox.insert(.size(columns: size.columns, rows: size.rows), at: 0)
            }
            if sizeClaimed { startLeaseRefresh() }
            drain()
            drainInput()
            openInputLane(for: client)
        } catch {
            heldEvents = nil
            lastError = LinkController.reason(error)
            log.error("attach surface \(self.surface): \(String(describing: error), privacy: .public)")
            if everAttached, attachRetries < reattachBackoff.count, handler != nil, !ended {
                // A reattach: keep the last frame and try again (bounded backoff).
                let delay = reattachBackoff[attachRetries]
                attachRetries += 1
                if let client = self.client { self.client = nil; Task { await client.close() } }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    self?.reconnect()
                }
                return
            }
            if everAttached {
                // Retries ran out: say what happened and how to go on. The failed
                // attach's channel closes now, not at the next reconnect (PR #22555 review).
                if let client = self.client { self.client = nil; Task { await client.close() } }
                eventTask?.cancel()
                eventTask = nil
                inbox?.close()
                inbox = nil
                gaveUp = true
                emitText("\r\n\u{1B}[2m[Can't reattach: \(lastError ?? "no answer from the Mac"). Type to try again.]\u{1B}[0m\r\n")
            } else {
                emitText("\r\n\u{1B}[2m[\(lastError ?? "Can't attach to this terminal")]\u{1B}[0m\r\n")
            }
        }
    }

    /// The channel ended. After `detached` that is the end; otherwise the link
    /// dropped and the session waits for ``reconnect()``.
    private func channelEnded(_ client: DaemonClient) {
        guard self.client === client else { return }
        self.client = nil
        dropInputLane()
        attached = false
        stopLeaseRefresh()
        markInputDetached()
        draining = false
        guard handler != nil, !ended else { return }
        handler?(.connection(connectionState))
        log.info("surface \(self.surface): link dropped, waiting to reattach")
    }

    /// One event line from the daemon channel, decoded on the main actor
    /// (tests; the attach stream decodes off the main actor).
    func handle(_ line: Data) {
        for event in lineParser.parse(line) { apply(event) }
    }

    private func apply(_ event: DaemonTerminalInbound) {
        switch event {
        case .output(let data):
            handler?(.output(data))
        case .alternateScreen(let on):
            setAlternate(on)
        case .columns(let columns):
            // Told with the rows that follow on the same line.
            if reportedColumns != columns { hostGridChanged = true }
            reportedColumns = columns
        case .rows(let rows):
            if reportedRows != rows { hostGridChanged = true }
            reportedRows = rows
            if hostGridChanged, let columns = reportedColumns {
                hostGridChanged = false
                handler?(.hostGrid(columns: columns, rows: rows))
            }
            // The Mac answered a size other than the one asked for (another
            // view of this terminal, the Mac's own window, sets the grid): the
            // request was overruled. A reattach then keeps the Mac's size
            // instead of resizing its PTY to the phone's grid and back, which
            // made an inline TUI (Codex) redraw its whole transcript twice
            // over the link (termqa D4/D8).
            if attached, let asked = lastSize, let columns = reportedColumns,
               asked.columns != columns || asked.rows != rows {
                overruled = Overruled(asked: asked, mac: (columns, rows))
            } else if attached, let asked = lastSize, asked.columns == reportedColumns, asked.rows == rows {
                overruled = nil
            }
        case .resetMirror(let alternate):
            log.notice("surface \(self.surface, privacy: .public): mirror reset cause=resized-event (rows \(self.reportedRows ?? -1, privacy: .public), last size asked \(self.lastSize.map { "\($0.columns)x\($0.rows)" } ?? "-", privacy: .public))")
            setAlternate(alternate)
            handler?(.output(Data("\u{1B}c".utf8)))
        case .detached(let reason):
            ended(reason: reason)
        case .sameGridResize(let columns, let rows):
            log.notice("surface \(self.surface, privacy: .public): resized event at the mirrored grid \(columns, privacy: .public)x\(rows, privacy: .public): kept, no reset")
        case .sizeState(let state, let participant):
            sizing.apply(state, selfParticipant: participant)
            noteHostGridOwner()
        }
    }

    /// The screen is behind: stop reading output from the Mac until it
    /// catches up (the link's own flow control then holds the Mac back).
    public func setOutputPaused(_ paused: Bool) {
        outputPaused = paused
        inbox?.setPaused(paused)
    }

    private func emitText(_ text: String) {
        handler?(.output(Data(text.utf8)))
    }

    private func setAlternate(_ on: Bool) {
        guard isAlternateScreen != on else { return }
        isAlternateScreen = on
        handler?(.alternateScreen(on))
    }

    private func ended(reason: String?) {
        guard handler != nil, !ended else { return }
        ended = true
        emitText("\r\n\u{1B}[2m[Detached\(reason.map { ": \($0)" } ?? "")]\u{1B}[0m\r\n")
        handler?(.exited(code: 0))
        attached = false
    }

    // MARK: Outbox

    private func enqueue(_ item: Outgoing) {
        outbox.append(item)
        drain()
    }

    private func drain() {
        guard attached, !draining, let client, !outbox.isEmpty else { return }
        draining = true
        let next = outbox.removeFirst()
        let surface = surface
        Task { [weak self] in
            guard let self else { return }
            do {
                let cmd: String
                let reply: Data
                switch next {
                case .size(let columns, let rows):
                    cmd = "resize-surface"
                    log.notice("surface \(surface, privacy: .public): resize-surface sent \(columns, privacy: .public)x\(rows, privacy: .public) cause=\(self.everAttached && self.attachRetries == 0 ? "requested" : "attach", privacy: .public)")
                    sizeClaimed = true
                    startLeaseRefresh()
                    reply = try await client.request(cmd, params: ["surface": surface, "cols": columns, "rows": rows])
                case .release:
                    cmd = "release-surface-size"
                    reply = try await client.request(cmd, params: ["surface": surface])
                }
                if let error = Self.error(in: reply) {
                    lastError = error
                    log.error("\(cmd, privacy: .public) failed: \(error, privacy: .public)")
                }
            } catch {
                // The channel failed under the request (a dead link): keep the
                // keystrokes for the reattach instead of dropping them.
                lastError = LinkController.reason(error)
                if self.client === client {
                    self.client = nil
                    attached = false
                    handler?(.connection(connectionState))
                }
                outbox.insert(next, at: 0)
                draining = false
                return
            }
            draining = false
            drain()
        }
    }

    // MARK: Input lane

    /// Opens the input-lane channel for the attach `main` (a no-op without
    /// `openInput`). It is dropped with the attach channel.
    private func openInputLane(for main: DaemonClient) {
        guard let openInput else { return }
        Task { [weak self] in
            guard let lane = try? await openInput() else { return }
            await lane.start()
            guard let self, self.client === main, self.attached, self.inputClient == nil else {
                await lane.close()
                return
            }
            self.inputClient = lane
            let events = lane.events
            Task { [weak self] in
                for await _ in events {}
                guard let self, self.inputClient === lane else { return }
                self.inputClient = nil
            }
        }
    }

    /// Closes the input-lane channel (the Mac drops its daemon connection).
    private func dropInputLane() {
        guard let lane = inputClient else { return }
        inputClient = nil
        Task { await lane.close() }
    }

    /// Sends queued keystrokes as one `send`, on the input lane when open,
    /// else on the attach channel. Keys that waited longer than
    /// `inputHoldLimit` are dropped first.
    ///
    /// The next batch goes out once this one is written, not when its reply
    /// comes (TUI fast scroll), up to `maxInputInFlight` unanswered. One
    /// small request at a time stalled a flick for the link's whole
    /// retransmission timeout (1 s, then 2 s) whenever a segment was lost on
    /// a relayed path; with later segments behind it, the duplicate ACKs
    /// repair the loss within a few segments. Writes stay in order (each
    /// waits for the last), and several are unanswered on one channel only:
    /// requests on two channels could reach the terminal out of order.
    ///
    /// When a channel fails, its other requests settle before anything new
    /// goes out (``inputSettled()``). A batch that was written may already
    /// have been typed on the Mac, and a doubled Return runs a command
    /// twice: it is never sent again, and neither is anything after it.
    private func drainInput() {
        guard attached, !inputWriting else { return }
        expireInput()
        guard !input.isEmpty, let target = inputClient ?? client else { return }
        if inputInFlight > 0, inputRecovering || inputTarget !== target || inputInFlight >= Self.maxInputInFlight { return }
        if let oldest = inputWrittenAt.values.min(), now() - oldest > inputStallLimit { return }
        inputWriting = true
        inputInFlight += 1
        inputTarget = target
        let number = nextInputBatch
        nextInputBatch += 1
        inputWrittenAt[number] = now()
        let typedAt = input[0].at
        let batch = input.reduce(into: Data()) { $0.append($1.bytes) }
        input.removeAll()
        let surface = surface
        let onLane = target !== client
        Task { [weak self] in
            guard let self else { return }
            var written = false
            do {
                let submit: @Sendable () async throws -> String = {
                    try await target.submit("send", params: ["surface": surface, "bytes": batch.base64EncodedString()])
                }
                // A lane request gets written and answered within seconds or
                // the lane is given up.
                let id: String
                if onLane {
                    guard let submitted = try await Self.within(.seconds(10), submit) else {
                        abandonInputLane(target, number: number, bytes: batch.count, wasWriting: true)
                        return
                    }
                    id = submitted
                } else {
                    id = try await submit()
                }
                written = true
                inputWriting = false
                inputProgress += 1
                armTailProbe()
                drainInput()
                let reply: Data
                if onLane {
                    guard let answer = try await Self.within(.seconds(10), { try await target.reply(to: id) }) else {
                        abandonInputLane(target, number: number, bytes: batch.count, wasWriting: false)
                        return
                    }
                    reply = answer
                } else {
                    reply = try await target.reply(to: id)
                }
                if let error = Self.error(in: reply) {
                    lastError = error
                    log.error("send failed: \(error, privacy: .public)")
                }
            } catch {
                if !written { inputWriting = false }
                lastError = LinkController.reason(error)
                inputRecovering = true
                if written || target === abandonedInputLane {
                    inputFailed.append((number, batch, typedAt, written: true))
                } else {
                    // Never written: safe to send again (on the attach channel
                    // when the lane failed, or after the reattach).
                    inputFailed.append((number, batch, typedAt, written: false))
                }
                if inputClient === target {
                    dropInputLane()
                } else if self.client === target {
                    self.client = nil
                    inputClient = nil
                    attached = false
                    // Fails this channel's other unanswered sends, which
                    // otherwise wait on a channel nobody reads.
                    Task { await target.close() }
                    handler?(.connection(connectionState))
                }
            }
            inputWrittenAt[number] = nil
            inputSettled()
        }
    }

    /// The input lane gave no answer in time (`wasWriting`: the batch's
    /// write itself hung): given up, and the batch is not sent again (the
    /// Mac may already have typed it).
    private func abandonInputLane(_ lane: DaemonClient, number: Int, bytes: Int, wasWriting: Bool) {
        log.error("send on the input lane got no answer; using the attach channel")
        abandonedInputLane = lane
        inputRecovering = true
        inputFailed.append((number, Data(count: bytes), now(), written: true))
        if wasWriting { inputWriting = false }
        inputWrittenAt[number] = nil
        if inputClient === lane { dropInputLane() }
        inputSettled()
    }

    /// A `send` was answered, failed or given up: the next batch may go.
    /// Once a failed channel's sends have all settled, its failed batches go
    /// back before newer keys, in order, unless one of them may have been
    /// typed already: then all of them are dropped and the screen is told.
    private func inputSettled() {
        inputInFlight -= 1
        inputProgress += 1
        guard inputInFlight == 0 else {
            armTailProbe()
            return drainInput()
        }
        tailProbe?.cancel()
        tailProbe = nil
        inputWrittenAt.removeAll()
        inputTarget = nil
        abandonedInputLane = nil
        if inputRecovering {
            inputRecovering = false
            let failed = inputFailed.sorted { $0.number < $1.number }
            inputFailed.removeAll()
            if failed.contains(where: \.written) {
                // The keys typed since go too: no part of a command may run
                // after an earlier part that may be lost.
                let bytes = failed.reduce(0) { $0 + $1.bytes.count } + input.reduce(0) { $0 + $1.bytes.count }
                input.removeAll()
                log.notice("surface \(self.surface, privacy: .public): \(bytes, privacy: .public) typed bytes not sent again (the Mac may have typed them before the channel failed)")
                handler?(.inputNotSent(bytes: bytes))
            } else if !failed.isEmpty {
                input.insert(contentsOf: failed.map { ($0.bytes, $0.at, true) }, at: 0)
                markInputDetached()
            }
        }
        drainInput()
    }

    /// TUI scroll tail: when a `send` stays unanswered for
    /// ``tailProbeDelay`` with no other progress, three `ping`s go behind it
    /// on the same channel (twice at most per stall). A segment lost at the
    /// end of a flick has nothing behind it to produce duplicate ACKs, so it
    /// waited out the 1 s retransmission timeout; the pings' segments (or
    /// their replies, for a lost reply) bring the three duplicate ACKs that
    /// retransmit it at once. Nothing typed is ever sent twice.
    private func armTailProbe() {
        tailProbe?.cancel()
        guard attached, inputInFlight > 0, !inputRecovering, let target = inputTarget else {
            tailProbe = nil
            return
        }
        let mark = inputProgress
        let delay = tailProbeDelay
        tailProbe = Task { [weak self] in
            for _ in 0..<2 {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, self?.tailProbeStillDue(mark: mark, target: target) == true else { return }
                var ids: [String] = []
                for _ in 0..<3 where !Task.isCancelled {
                    guard let id = try? await target.submit("ping") else { break }
                    ids.append(id)
                }
                // Collect the replies so none is left waiting in the client
                // (they end with the channel if it never answers).
                let sent = ids
                Task { for id in sent { _ = try? await target.reply(to: id) } }
            }
        }
    }

    /// Nothing was written or answered since the probe was armed, and the
    /// stalled sends are still on `target`.
    private func tailProbeStillDue(mark: Int, target: DaemonClient) -> Bool {
        guard attached, inputProgress == mark, inputInFlight > 0, !inputRecovering, inputTarget === target else { return false }
        log.info("surface \(self.surface, privacy: .public): send unanswered for \(self.tailProbeDelay, privacy: .public); tail probe")
        return true
    }

    /// One main-queue turn's input goes out as one `send`: Ghostty writes a
    /// scroll frame's wheel reports one by one.
    private func scheduleInputDrain() {
        guard !inputDrainScheduled else { return }
        inputDrainScheduled = true
        Task { [weak self] in
            guard let self else { return }
            inputDrainScheduled = false
            drainInput()
        }
    }

    /// `operation`'s result, or nil when it takes longer than `limit`. Does
    /// not wait for `operation` to notice cancellation (a request on a dead
    /// channel never does).
    private static func within<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
        let once = RaceOnce()
        let result: Result<T?, any Error> = await withCheckedContinuation { continuation in
            let timer = TaskBox()
            let work = Task {
                let result: Result<T?, any Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                if once.claim() {
                    timer.cancel()
                    continuation.resume(returning: result)
                }
            }
            timer.set(Task {
                try? await Task.sleep(for: limit)
                if !Task.isCancelled, once.claim() {
                    work.cancel()
                    continuation.resume(returning: .success(nil))
                }
            })
        }
        return try result.get()
    }

    /// The Mac's columns (`vt-state`, `resized`).
    private var reportedColumns: Int?
    /// The phone's last size request the Mac answered with another size.
    private struct Overruled { var asked: (columns: Int, rows: Int); var mac: (columns: Int, rows: Int) }
    private var overruled: Overruled?

    /// Events that arrived before the Mac confirmed the attach (nil: none held).
    private var heldEvents: [DaemonTerminalInbound]?
    /// Failed reattach attempts since the last good attach.
    private var attachRetries = 0
    /// The reattach retries ran out; the next keystroke tries again.
    private var gaveUp = false
    /// Delays before retrying a failed reattach (seconds); then the error shows.
    static let defaultReattachBackoff: [Double] = [0.25, 0.5, 1, 2, 4, 8]
    var reattachBackoff = DaemonTerminalSession.defaultReattachBackoff

    /// The size the attach already carried (no separate resize needed).
    private var attachedWithSize: (columns: Int, rows: Int)?

    /// The surfaces to attach again on a new link: every open session's,
    /// except one the Mac's tree no longer lists (its tab was closed). Before
    /// the tree is known, all of them.
    /// A session exists only for a tab the phone saw in the tree, so a
    /// surface the tree no longer lists is a closed tab, not a new one.
    nonisolated public static func surfacesToReattach(_ sessions: [Int], tree: Set<Int>?) -> [Int] {
        guard let tree else { return sessions }
        return sessions.filter(tree.contains)
    }

    /// Whether a session attaches again on a new link: its surface is still
    /// listed, or its terminal is (on another surface after the Mac's daemon
    /// restarted; the reattach finds it by id). Before the tree is known, yes.
    nonisolated public static func shouldReattach(surface: Int, terminalID: String?, tree: DaemonTree?) -> Bool {
        guard let tree else { return true }
        if tree.surfaces.values.contains(surface) { return true }
        guard let terminalID else { return false }
        return tree.terminals.values.contains { $0.resourceID == terminalID || $0.id == terminalID }
    }

    // MARK: Size lease

    /// Listed in `set-client-info` and by the daemon in `identify`.
    static let sizeLeaseCapability = "size-lease-v1"
    /// Shared sizing: `size-state` on the attach stream, `note-size-activity`.
    static let sharedSizingCapability = "shared-sizing-v1"
    /// `host-grid-view-v1`: this phone renders a Mac grid larger than its
    /// own (pans, letterboxes), so the daemon need not cap the PTY at it.
    static let hostGridViewCapability = "host-grid-view-v1"
    /// What the attach channel lists in `set-client-info`.
    static let clientCapabilities = [sizeLeaseCapability, sharedSizingCapability, hostGridViewCapability]

    /// While the size is claimed and the daemon leases it: the same size
    /// again every `sizeLeaseRefresh` (a same-size `resize-surface` renews
    /// the lease and never resizes the terminal). One refresher at a time.
    private func startLeaseRefresh() {
        guard leased, claimsSize, leaseTask == nil else { return }
        let interval = sizeLeaseRefresh
        // The lease's own cadence (an intentional bounded delay), not a sync wait.
        leaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.refreshLease()
            }
        }
    }

    private func stopLeaseRefresh() {
        leaseTask?.cancel()
        leaseTask = nil
    }

    private func refreshLease() {
        guard attached, claimsSize, sizeClaimed, let size = lastSize else { return }
        // A refresh already queued, or a resize on its way, renews it too.
        guard !outbox.contains(where: { if case .size = $0 { true } else { false } }) else { return }
        enqueue(.size(columns: size.columns, rows: size.rows))
    }

    nonisolated static func lists(_ capability: String, _ identify: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: identify) as? [String: Any],
              let data = object["data"] as? [String: Any],
              let capabilities = data["capabilities"] as? [String] else { return false }
        return capabilities.contains(capability)
    }

    /// Whether the daemon takes the viewer's size in `attach-surface`.
    nonisolated static func acceptsInitialSize(_ identify: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: identify) as? [String: Any],
              let data = object["data"] as? [String: Any],
              let capabilities = data["capabilities"] as? [String] else { return false }
        return capabilities.contains("attach-initial-size")
    }

    private static func error(in reply: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return "bad reply" }
        if object["ok"] as? Bool == false { return (object["error"] as? String) ?? "refused" }
        if let error = object["error"] as? String { return error }
        return nil
    }
}

/// A task another task may cancel once it is set (``DaemonTerminalSession/within``).
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func set(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}
