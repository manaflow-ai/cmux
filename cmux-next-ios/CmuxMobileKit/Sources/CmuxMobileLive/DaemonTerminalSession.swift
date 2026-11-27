#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif
import CmuxMobileDesign
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
/// - Latest screen first (`attach-replay-history-rows-v1`, cmuxterm-hq#7231):
///   against a daemon that lists it, the attach asks for the screen alone
///   (`replay_history_rows`), so the terminal is live after one screen of
///   bytes instead of its whole scrollback. Older rows come when the reader
///   scrolls up to them (``loadOlderHistory()``): a second attach with
///   ``historyChunkRows`` more rows replaces the first. An older daemon gets
///   no field and replays the whole history, as before.
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
    /// The Mac terminal's rows the screen was shown (`vt-state`, `resized`),
    /// else the size asked for. A grid the reclaim hold keeps back is not the
    /// screen's yet: read here, the page laid its mirror out at the Mac's
    /// 118x69 while the phone's claim was out (Leo, 2026-11-23: "im sometimes
    /// seeing these 118x69 load ins which are wide... then it properly goes").
    public var remoteRows: Int? { shownGrid?.rows ?? lastSize?.rows ?? 24 }
    private var reportedRows: Int?
    /// The Mac's grid changed since the screen was last told (``TerminalSessionEvent/hostGrid(columns:rows:)``).
    private var hostGridChanged = false
    /// The Mac terminal's columns the screen was shown (`vt-state`,
    /// `resized`); nil before the first grid reaches the screen. The screen
    /// renders this grid when it is not the phone's.
    public var remoteColumns: Int? { shownGrid?.columns }
    /// The last grid given to the screen (past the reclaim hold).
    private var shownGrid: (columns: Int, rows: Int)?

    /// Gives the screen events past the reclaim hold, noting the grid it now has.
    private func deliver(_ events: [TerminalSessionEvent]) {
        for event in events {
            if case .hostGrid(let columns, let rows) = event { shownGrid = (columns, rows) }
            handler?(event)
        }
    }
    /// The owner the screen was last told (``TerminalSessionEvent/hostGridOwner(_:)``).
    private var toldHostGridOwner: String??

    /// Tells the screen when the device that sets the grid changed.
    private func noteHostGridOwner() {
        let name = hostGridOwnerName
        guard toldHostGridOwner != .some(name) else { return }
        toldHostGridOwner = .some(name)
        handler?(.hostGridOwner(name))
    }

    /// The device that sets the Mac's grid, other than this view: the first
    /// owner that is not this phone's view. Several views can own one grid
    /// (under Fit the Smallest Viewer a narrow Mac pane sets the columns
    /// while the phone sets the rows), so the phone owning one dimension
    /// still names the device that set the other. Nil when no other view
    /// owns it; the note then names no device.
    public var hostGridOwnerName: String? {
        guard let state = sizing.state else { return nil }
        let others = state.owners.filter { $0 != sizing.selfParticipant }
        guard let row = others.lazy.compactMap({ owner in state.participants.first { $0.id == owner } }).first
        else { return nil }
        // Another view of this same phone (a second page on the terminal).
        if let own = clientInfo["device_id"], row.deviceID == own, !row.isDesktop { return "this iPhone" }
        if let name = row.deviceName ?? row.displayName { return name }
        switch row.deviceKind {
        case "mac": return "a Mac"
        case "iphone": return "an iPhone"
        case "ipad": return "an iPad"
        case "tui": return "a terminal"
        default: return nil
        }
    }
    /// The last attach or send failure (shown nowhere yet; logged).
    public private(set) var lastError: String?

    /// The raw failure for `lastError`, which goes to the log only (never on
    /// screen): the Mac's own words, so a log reads "unknown surface 9" and not
    /// the sentence a person sees.
    nonisolated static func diagnostic(_ error: any Error) -> String {
        if let error = error as? LinkError { return error.message.isEmpty ? error.code : String(error.message.prefix(160)) }
        return String(error.localizedDescription.prefix(160))
    }

    /// The terminal's shared size state, live while attached to a daemon
    /// with `shared-sizing-v1`.
    public let sizing = TerminalSizingLive()
    /// The daemon takes `note-size-activity` (it listed `shared-sizing-v1`).
    private var sharedSizing = false
    /// The daemon takes `replay_history_rows` (it listed
    /// `attach-replay-history-rows-v1`, and its lane did not refuse it).
    private var tailReplay = false
    /// The daemon lists `send-expect-agent-v1`: `send` takes `submit` with
    /// `paste` (``sendPasteAndSubmit(_:notSent:maybeSent:)``). An older daemon ignores `submit`
    /// and would paste the draft with no Return: it gets the mirror's paste.
    private var pasteSubmit = false
    /// The daemon lists `send-typed-submit-v1`: `send {text, submit:true}`
    /// with no `paste` writes Return a paste-burst window after the typed
    /// text, in the same request (``sendTypedAndSubmit(_:notSent:maybeSent:)``).
    private var typedSubmit = false
    /// Composer sends (by their id in `input`, `paste`) that go as typed text,
    /// not a paste, where the request is built here (no Rust outbox).
    private var typedSends: Set<Int> = []
    /// The `agent-cli-frame` stream and the newest frame this mirror drew
    /// (`agent-cli-hybrid-v1`): a reattach names them, so the Mac sends what changed
    /// since that frame instead of the whole screen.
    private var hybridResume: (stream: String, frame: Int)?
    /// Where this mirror stands in the Mac's byte stream (`terminal-resume-v1`): the offset
    /// after the last byte drawn and its generation. A reattach names it, and the Mac sends
    /// only the bytes the phone missed while it was away (the app switched to dictate, a
    /// dropped link) instead of a reset and a whole replay with history (Leo, 2026-11-24:
    /// "The like multi-second long reattach").
    private var streamPosition: TerminalStreamPosition?
    /// The bytes the last whole replay took: a resume past it costs more than a replay.
    private var lastReplayBytes: Int?
    /// Agent CLI frames this session could not draw (``DaemonTerminalInbound/hybridFallback(reason:)``).
    /// The first makes a full resync (an attach that names no frame: a keyframe); after the
    /// second the session attaches in bytes mode (it declares no hybrid capability).
    private(set) var hybridFallbacks = 0
    /// The attach whose frame failed is closing: attach again once it has.
    private var resyncAfterClose = false
    /// The session declares the hybrid capabilities: the setting is on and its frames did
    /// not fail twice.
    private var hybridWanted: Bool { Self.agentCLIHybridEnabled(agentCLIHybridDefaults) && hybridFallbacks < 2 }
    /// Where the setting is read (tests give each session its own).
    var agentCLIHybridDefaults: UserDefaults = .standard
    /// History rows the next attach asks for above the screen (nil: all of
    /// them). Grows by ``historyChunkRows`` with each ``loadOlderHistory()``,
    /// and a reattach keeps it, so a reader keeps the rows they had.
    private(set) var historyAllowance: Int? = DaemonTerminalSession.initialHistoryRows
    /// Rows of the Mac's history older than the mirror's oldest row (the
    /// last `vt-state`'s `history_rows_omitted`; 0: the mirror has them all).
    public private(set) var historyRowsOmitted = 0
    /// The attach a ``loadOlderHistory()`` replaces, while the new one is out.
    private var replacing: DaemonClient?
    /// Rows of history the first attach asks for: none, the screen alone.
    static let initialHistoryRows = 0
    /// Rows each ``loadOlderHistory()`` adds (a bounded chunk: about 200 KB
    /// of a typical shell's history).
    static let historyChunkRows = 2_000
    /// The daemon takes `replay_history_start` (it listed
    /// `attach-replay-history-window-v1`, and its lane did not refuse it).
    private var windowReplay = false
    /// The lane refused `replay_history_start` (a Mac app older than its
    /// daemon): this session fetches the newest rows in chunks from then on,
    /// though `identify` still lists the window.
    private var windowRefused = false
    /// The first history row of the window the mirror holds far above the
    /// Mac's screen (`replay_history_start`); nil: the newest rows
    /// (``historyAllowance``). A reattach keeps it, so a reader keeps their rows.
    private(set) var historyWindowStart: Int?
    /// History rows between the mirror's window and the Mac's screen, left
    /// out (the last `vt-state`'s `history_rows_skipped`); 0: the mirror's
    /// rows reach the screen.
    public private(set) var historyRowsSkipped = 0
    /// The newest history rows the mirror holds at most. Scrolling past them,
    /// it holds a window of ``historyWindowRows`` instead, moved
    /// ``historyWindowStep`` rows at a time: its memory and each replay stay bounded
    /// however long the Mac's history is, and the reader still reaches line 1.
    static let maxTailHistoryRows = 5 * historyChunkRows
    /// Rows of a window far above the screen: the chunk read and one more.
    static let historyWindowRows = 2 * historyChunkRows
    /// Rows a window moves per fetch: under the reading mark's search
    /// (`TerminalReadingMark.searchRows`), so the replay puts the reader back
    /// on their rows, which moved by this much in the mirror.
    static let historyWindowStep = 1_500
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
    /// `send` (``drainInput()``). Keys held past the reconnect giving up
    /// (``expireInput()``) are dropped, never sent late (termfix-r13 D5:
    /// a command typed during an outage ran 15.4 minutes later).
    /// `typed`: the person's own input; false for Ghostty's replies to
    /// terminal queries (``sendReply(_:)``), which are never "keys not sent".
    /// `key`: a batch that may already have reached the Mac, put back to go
    /// again once, alone and under its first `send` key (``sendKeys``); nil
    /// for new keys. `paste`: the bytes are the composer's draft (UTF-8), sent
    /// alone as `send {text, paste:true, submit:true}` (``sendPasteAndSubmit(_:notSent:maybeSent:)``).
    private var input: [(bytes: Data, at: TimeInterval, detached: Bool, typed: Bool, key: String?, paste: Int?)] = []
    /// The Mac's daemon lists `send-key-v1` (its latest `identify`): a `send`
    /// carries a key, and one with a key it already applied writes nothing.
    /// A batch that may have arrived before its channel failed is then sent
    /// again once under the same key instead of dropped with "keys not sent"
    /// (Leo, 2026-11-21: "there's like a sort of like double send type
    /// thing": the dropped text went back to the composer, and a second Send
    /// typed it twice when the first had arrived).
    private var sendKeys = false
    /// A composer paste's "not sent" and "may have been sent" calls, by its id
    /// in `input` (`paste`): one is called once when the paste is given up,
    /// refused or answered with an error, and both are forgotten once the
    /// daemon applies it.
    private var pasteNotSent: [Int: (notSent: @MainActor () -> Void, maybeSent: @MainActor () -> Void)] = [:]
    private var nextPaste = 0
    #if canImport(CmuxMobileLinkFFI)
    /// The composer's Sends until the Mac answers them (Rust, `cmux-composer-send`). Each is one
    /// keyed `send` (the draft and its Return), made at the tap; every attempt, on any channel
    /// and after any reattach, carries that key, and the daemon types a key once. A Send whose
    /// answer was lost goes again under it instead of being dropped, and one given up after it
    /// went out is "may have been sent", never put back in the composer to be sent twice (Leo,
    /// 2026-11-23: "there's like a sort of like double send type thing"). `paste` ids in `input`
    /// are its Send numbers.
    private let composerOutbox = ComposerOutbox(
        nonce: "ios-\(UUID().uuidString)",
        holdMs: UInt64(DaemonTerminalSession.inputHoldLimit * 1000)
    )
    #endif
    /// The latest attach read the daemon's `identify` (``pasteSubmit``, ``sendKeys``). Before it,
    /// a composer Send waits in the outbox for the attach instead of going through the mirror as a
    /// paste and a separate Return.
    private var identified = false
    /// Keys queued while detached expired: everything typed until the next
    /// attach is refused, so no fragment of a command (its last 2 s) can
    /// reach the shell after the rest was dropped (r13 review).
    private var refusingInput = false
    /// How long typed keys may wait for the terminal (a blip) before they
    /// are dropped and the screen is told (seconds). An LTE handover or a
    /// relay reconnect takes a few seconds; 2 s dropped the keys of most
    /// blips and said so (Leo, 2026-11-12, on LTE: "thjs chatters too often
    /// with connectivity"). 10 s rides those out and still never runs a
    /// command long after it was typed (termfix-r13 D5).
    nonisolated public static let inputHoldLimit: TimeInterval = 10
    /// Keys typed while the terminal reconnects wait for the attach however long the
    /// reconnect takes: they are dropped when it gives up (its retries ran out, or the Mac
    /// stayed offline for `inputHoldLimit`), not 10 s after they were typed (Leo,
    /// 2026-11-24, back from another app: "I can't interact with anything at all"). This
    /// ceiling is far past any reconnect (its backoff gives up in about 16 s, the link
    /// calls the Mac offline after 4-8 s): it only covers an app suspended with keys
    /// queued, whose next attach must not type them minutes later (termfix-r13 D5).
    nonisolated public static let inputHoldCeiling: TimeInterval = 60
    /// When the coordinator last called the Mac offline (``now``'s clock), while it is.
    private var offlineSince: TimeInterval?
    /// The Mac link's last progress (``MacSession/progress``, set by the coordinator): every event
    /// line heard on the attach channel tells it, and keys held while the Mac is called offline
    /// go after ``inputHoldLimit`` of silence on it, not 10 s after the Mac went offline (Leo,
    /// 2026-11-24: "if it's making good progress, it shiukd be allowed to keep going?"). Nil (a
    /// bench, a test): the hold runs from the key and the Mac going offline, as before.
    public var linkProgress: LinkProgress?
    /// The input lane's own progress (its answers, its writes taken): a lane wait is bounded by
    /// silence on the lane itself, since traffic on the attach channel must not keep a stuck
    /// lane alive (falling back to the attach channel is the lane's recovery). New per lane.
    private var laneProgress = LinkProgress()
    /// Looks at the held keys again when progress on the link kept them past a check.
    private var heldKeysRecheck: Task<Void, Never>?
    /// At most this many typed bytes wait for a detached terminal; past it
    /// the queue is dropped as an expired one is (a long paste into a dead
    /// link is not replayed whole into whatever runs when it comes back).
    public static let inputHoldBytes = 16 * 1024
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
    /// A send that made no progress for this long (no bytes taken by the link, no answer to an
    /// earlier send) frees its slot and reports uncertain delivery. A send that keeps moving
    /// goes on, up to ``DaemonClient/progressCeiling`` (Leo, 2026-11-24: "a 10s timeout that
    /// kills messages while they're making progress is a shame. make it progress-based, not a
    /// wall clock").
    var inputRequestDeadline: Duration = .seconds(10)
    /// Sends answered later than ``inputRequestDeadline`` after they went out: each one the old
    /// fixed 10 s cut would have dropped while it was still moving.
    private(set) var sendsPastFixedDeadline = 0
    /// How long a `send` may go unanswered before ``armTailProbe()`` writes
    /// `ping`s behind it: many round trips, well under the 1 s RTO.
    var tailProbeDelay: Duration = .milliseconds(150)
    /// Writes and answers so far: a probe fires only if none came since it was armed.
    private var inputProgress = 0
    private var tailProbe: Task<Void, Never>?
    /// Sends written and not yet answered (tests).
    var inputsInFlight: Int { inputInFlight }
    /// The oldest typed batch whose echo has not come yet: its number and its first key's tap.
    /// The first output after it is its echo (PROTOCOL.md "Link stats", `echo`).
    private var echoDue: (number: Int, typedAt: TimeInterval)?
    /// The Mac's answer to the `echoDue` batch, ms after its tap, when it came first.
    private var echoDueAckMs: UInt32?
    /// A tail probe is armed (tests).
    var tailProbeArmed: Bool { tailProbe != nil }
    private var nextInputBatch = 0
    /// Batches of the failed channel, held until its sends all settle.
    /// `key`: the batch's `send` key (nil: the Mac takes none); `resent`: it
    /// was already a resend under that key.
    private var inputFailed: [(number: Int, bytes: Data, at: TimeInterval, written: Bool, typed: Int, key: String?, resent: Bool, paste: Int?)] = []
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
    /// The Mac's grid while this page is hidden, held until a claim brings
    /// the phone's grid back (`TerminalReclaimHold`).
    private var reclaimHold = TerminalReclaimHold()
    /// Shows what is held when a claim has not brought the phone's grid back.
    private var reclaimDeadline: Task<Void, Never>?
    /// How long a claim may take (tests shorten it).
    var reclaimWait: Duration = TerminalReclaimHold.reclaimWait
    /// The Mac holds a size of this session's now (a sized attach or a
    /// `resize-surface` went out, and no release after it).
    private var sizeClaimed = false
    /// The daemon lists `size-lease-v1` or `size-lease-v2`: a claim lasts
    /// only while refreshed.
    private var leased = false
    /// The daemon lists `size-lease-v2`: its lease is 8 s, not 45 s.
    private var shortLease = false
    /// How often a claimed size is sent again under `size-lease-v1` (the
    /// daemon's lease is 45 s).
    var sizeLeaseRefresh: Duration = .seconds(15)
    /// How often under `size-lease-v2` (the daemon's lease is 8 s, so three
    /// refreshes may go missing).
    var shortLeaseRefresh: Duration = .seconds(2)
    /// On screen, the Mac answered the phone's claim with another grid and
    /// kept it past ``reclaimWait`` (its policy keeps that grid): its grid
    /// changes are shown as they come, not held, until the phone's grid is
    /// back or the page claims again.
    private var macKeepsGrid = false
    /// Releases sent at once (``releaseNow()``) and not answered yet: a stop
    /// still sends its own, answered release before it closes the channel.
    private var releasesInFlight = 0
    /// The write of the last release sent at once (``releaseNow()``). A
    /// size claimed after it (shown again) waits for this write, so the Mac
    /// reads the release and then the claim: two tasks raced for the
    /// channel, and a claim that won left the Mac with no claim at all.
    private var releaseWritten: Task<Void, Never>?
    /// When this view last told the Mac its size (a sized attach or a
    /// `resize-surface`). A grid the phone did not ask for that arrives
    /// within ``claimAnswerWindow`` of it is that claim's own round trip (an
    /// attach's replay of the Mac's old grid), not a lost claim.
    private var lastClaimAt: ContinuousClock.Instant?
    /// How long a claim is still being answered (tests shorten it).
    var claimAnswerWindow: Duration = .milliseconds(1500)
    /// Claims ``claimAgain()`` sent (tests read it synchronously: it is set
    /// in the same turn as the grid that caused it).
    private(set) var reclaimsSent = 0
    private var leaseTask: Task<Void, Never>?
    private var draining = false
    /// The request `drain()` has on its way (while `draining`) is a size.
    private var drainingSize = false
    /// Bumped on every show/hide (``setClaimsSize(_:)``): a size `drain()` took
    /// under an older one is stale and never sent (a hide and show between
    /// queuing and sending queued the current size again).
    private var claimGeneration = 0
    private var pendingSize: (columns: Int, rows: Int)?
    /// The grid last asked for, put back after a reattach.
    private var lastSize: (columns: Int, rows: Int)?
    private var attached = false
    private var attaching = false
    /// A ``reconnect()`` came while an attach ran (the link was served meanwhile): the attach
    /// that is out may have looked for the link before it came, so one that ends waiting for the
    /// link attaches again at once instead of waiting for a link that is already here.
    private var reconnectWhileAttaching = false
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
        // gone says so; a reattach that gave up (it starts again on its own)
        // shows its last screen too.
        if attached || ended { return .attached }
        if macOffline { return .offline(mac: macName) }
        // Plain words: the transport's error (`lastError`) goes to the log only.
        if gaveUp { return .failed(message: Self.unreachableMessage(macName)) }
        return everAttached ? .reattaching(mac: macName) : .connecting(mac: macName)
    }

    /// The coordinator's word on the Mac (`LinkMachine.Phase.showsTerminalsOffline`).
    private var macOffline = false

    /// The Mac is offline or out of reach (true), or back (false). A
    /// detached session then says so instead of "Reattaching…" forever
    /// (termfix-r13 D4, T-LIFE-13); an attached one is unaffected.
    public func setMacOffline(_ offline: Bool) {
        guard offline != macOffline else { return }
        // Back: keys that waited out the hold while it was offline go now, before the attach.
        if !offline { expireInput() }
        let before = connectionState
        macOffline = offline
        offlineSince = offline ? now() : nil
        let after = connectionState
        if after != before, handler != nil, !ended { handler?(.connection(after)) }
        if offline { scheduleInputExpiry(after: Self.inputHoldLimit) }
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
        enqueueTyped(bytes, paste: nil)
    }

    /// The composer's Send as one `send {surface, text, paste:true,
    /// submit:true}`, in order with the keys queued before it: the daemon
    /// brackets the draft by the terminal's own mode 2004 (the mirror's may
    /// be lost after a replay) and writes Return in the same request.
    /// False against a daemon that does not list `send-expect-agent-v1`, or
    /// before the first attach said which daemon this is.
    public func sendPasteAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void, maybeSent: @escaping @MainActor () -> Void) -> Bool {
        #if canImport(CmuxMobileLinkFFI)
        guard !text.isEmpty, pasteSubmit || !identified else { return false }
        let id = Int(composerOutbox.push(text: text, submit: true, nowMs: Self.milliseconds(now())))
        #else
        guard pasteSubmit, !text.isEmpty else { return false }
        let id = nextPaste
        nextPaste += 1
        #endif
        pasteNotSent[id] = (notSent, maybeSent)
        enqueueTyped(Data(text.utf8), paste: id)
        return true
    }

    /// The composer's Send of a one-line draft to a full-screen program, as
    /// one keyed `send {surface, text, submit:true}`: typed (vim takes a
    /// bracketed paste as text even in normal mode), with Return in the same
    /// request, so a link blip can never deliver the text without its Return
    /// (Leo, 2026-11-21: "the text goes through. But then the send doesn't go
    /// through"). Held through a blip and sent once, like a pasted Send. False
    /// against a daemon that does not list `send-typed-submit-v1` (one that
    /// would write Return right behind the text, inside an agent's paste-burst
    /// window): the screen keeps the mirror's path there.
    public func sendTypedAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void, maybeSent: @escaping @MainActor () -> Void) -> Bool {
        #if canImport(CmuxMobileLinkFFI)
        guard !text.isEmpty, (pasteSubmit && typedSubmit) || !identified else { return false }
        let id = Int(composerOutbox.pushTyped(text: text, nowMs: Self.milliseconds(now())))
        #else
        guard pasteSubmit, typedSubmit, !text.isEmpty else { return false }
        let id = nextPaste
        nextPaste += 1
        typedSends.insert(id)
        #endif
        pasteNotSent[id] = (notSent, maybeSent)
        enqueueTyped(Data(text.utf8), paste: id)
        return true
    }

    /// Gives a composer paste up and tells the screen (once): "may have been sent" when an
    /// attempt went out (``composerOutbox``), else "not sent".
    private func pasteWasNotSent(_ id: Int?) {
        guard let id else { return }
        #if canImport(CmuxMobileLinkFFI)
        // In flight (its answer settles it) or already settled: nothing to give up here.
        guard let done = composerOutbox.giveUpSend(seq: UInt64(id)) else { return }
        composerSendEnded(done)
        #else
        typedSends.remove(id)
        pasteNotSent.removeValue(forKey: id)?.notSent()
        #endif
    }

    #if canImport(CmuxMobileLinkFFI)
    /// The daemon's answer to the composer Send `id`'s request: applied, refused, or an error that
    /// may have typed it. A lost answer is ``ComposerSendAnswer/lost``: it goes again under its key.
    private func composerAnswered(_ id: Int, _ answer: ComposerSendAnswer) {
        guard let done = composerOutbox.answer(seq: UInt64(id), answer: answer) else { return }
        composerSendEnded(done)
    }

    private func composerSendEnded(_ done: ComposerSendDone) {
        guard let calls = pasteNotSent.removeValue(forKey: Int(done.seq)) else { return }
        switch done.outcome {
        case .sent: break
        case .notSent: calls.notSent()
        case .maybeSent: calls.maybeSent()
        }
    }

    /// The attached daemon takes no `send` keys: every queued composer Send is given up (a resend
    /// there could type it twice), and the screen gets back the ones that never went out.
    private func giveUpComposerSends() {
        input.removeAll { $0.paste != nil }
        composerOutbox.giveUp().forEach(composerSendEnded)
    }
    #endif

    nonisolated static func milliseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1000)
    }

    private func enqueueTyped(_ bytes: Data, paste: Int?) {
        // A reattach that gave up: typing tries again (the line it printed says so).
        if gaveUp { reconnect() }
        if refusingInput, !attached {
            log.notice("surface \(self.surface, privacy: .public): \(bytes.count, privacy: .public) typed bytes refused (earlier keys were already dropped)")
            handler?(.inputNotSent(bytes: bytes.count))
            pasteWasNotSent(paste)
            return
        }
        input.append((bytes, now(), !attached, true, nil, paste))
        if !attached, input.reduce(0, { $0 + $1.bytes.count }) > Self.inputHoldBytes {
            dropDetachedInput(reason: "more than \(Self.inputHoldBytes) bytes waited for the terminal")
            return
        }
        if attached {
            scheduleInputDrain()
            noteInteraction()
        } else {
            // Held for the attach while the terminal reconnects; dropped when the reconnect
            // gives up (``expireInput()``), and the screen says so then.
            scheduleInputExpiry(after: macOffline ? Self.inputHoldLimit : Self.inputHoldCeiling)
            reportHeldInput()
        }
    }

    /// Typed bytes the screen was last told wait for the attach (``reportHeldInput()``).
    private var reportedHeldBytes = 0

    /// Tells the screen how many typed bytes wait for the attach (`.inputHeld`), when that
    /// changed: the composer says keys are pending and offers Discard while there are any,
    /// since they will be typed into whatever the terminal shows after the attach.
    private func reportHeldInput() {
        let held = attached ? 0 : input.reduce(0) { $0 + ($1.detached && $1.typed ? $1.bytes.count : 0) }
        guard held != reportedHeldBytes else { return }
        reportedHeldBytes = held
        if handler != nil, !ended { handler?(.inputHeld(bytes: held)) }
    }

    /// The person discarded the keys held for the attach: none of them is sent, and nothing
    /// says "not sent" (they chose it). A held composer send comes back to the composer.
    /// Typing goes on queueing for the attach. A no-op while attached.
    public func discardHeldInput() {
        guard !attached, !input.isEmpty else { return }
        let bytes = input.reduce(0) { $0 + ($1.typed ? $1.bytes.count : 0) }
        let pastes = input.compactMap(\.paste)
        input.removeAll()
        log.notice("surface \(self.surface, privacy: .public): \(bytes, privacy: .public) held typed bytes discarded by the person")
        pastes.forEach(pasteWasNotSent)
        reportHeldInput()
    }

    /// Checks the held keys against the hold (``expireInput()``) after `delay`.
    private func scheduleInputExpiry(after delay: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.expireInput()
        }
    }

    /// A reply the terminal wrote by itself (a cursor or device report, a
    /// focus or mouse report): sent only while attached. Held through an
    /// outage it would be stale, and its drop is no key the person typed, so
    /// it is never queued for a reattach, never refused and never makes the
    /// "Keys typed while your Mac was unreachable" notice (Leo, 2026-11-12:
    /// "thjs chatters too often with connectivity").
    public func sendReply(_ bytes: Data) {
        guard !bytes.isEmpty, attached, !refusingInput else { return }
        input.append((bytes, now(), false, false, nil, nil))
        scheduleInputDrain()
    }

    /// The terminal is unreachable: every key still queued now waits for a
    /// detached terminal, from when it was typed.
    private func markInputDetached() {
        // A reply waiting to go is stale once the link drops: never sent
        // after a reattach (the screen is replayed by then).
        input = input.filter(\.typed).map { ($0.bytes, $0.at, true, true, $0.key, $0.paste) }
        guard !input.isEmpty else { return }
        scheduleInputExpiry(after: macOffline ? Self.inputHoldLimit : Self.inputHoldCeiling)
        reportHeldInput()
    }

    /// Keys held for a detached terminal whose reconnect gave up: all queued
    /// keys are dropped (never only the oldest: the rest of a command must not
    /// run alone), input is refused until the next attach, and the screen is
    /// told. Held, not dropped, while the terminal reconnects
    /// (``inputHoldCeiling``). Keys typed while attached (a slow but live link)
    /// never expire here.
    private func expireInput() {
        heldKeysRecheck?.cancel()
        heldKeysRecheck = nil
        let typedAt = input.filter(\.detached).map(\.at)
        let progressAge = linkProgress?.lastProgressAge()
        let offline = macOffline ? offlineSince : nil
        guard let reason = Self.heldInputExpiry(typedAt: typedAt, now: now(), gaveUp: gaveUp,
                                                offlineSince: offline, progressAge: progressAge) else {
            // Progress since the Mac went offline kept them: look again once that progress is a
            // hold old (each look is one timer; the ceiling ends them).
            if !typedAt.isEmpty, offline != nil, let progressAge, progressAge < Self.inputHoldLimit {
                let delay = max(0.25, Self.inputHoldLimit - progressAge)
                heldKeysRecheck = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    self?.expireInput()
                }
            }
            return
        }
        dropDetachedInput(reason: reason)
    }

    /// Why keys held for a detached terminal (typed at `typedAt`) go now, or nil while
    /// they wait for the attach: the reconnect gave up, the Mac was offline and the link made
    /// no progress for ``inputHoldLimit`` since the later of the key, the Mac going offline and
    /// its last progress (`progressAge` seconds ago), or a key is past ``inputHoldCeiling``.
    /// Rust decides (`held_keys_expiry`, `cmux_composer_send::progress`).
    nonisolated static func heldInputExpiry(typedAt: [TimeInterval], now: TimeInterval, gaveUp: Bool,
                                            offlineSince: TimeInterval?, progressAge: TimeInterval? = nil) -> String? {
        guard !typedAt.isEmpty else { return nil }
        #if canImport(CmuxMobileLinkFFI)
        func ms(_ seconds: TimeInterval) -> UInt64 { UInt64(max(0, seconds * 1000).rounded()) }
        let reason = CmuxMobileLinkFFI.heldKeysExpiry(
            typedAgesMs: typedAt.map { ms(now - $0) }, gaveUp: gaveUp,
            offlineAgeMs: offlineSince.map { ms(now - $0) }, progressAgeMs: progressAge.map(ms),
            holdMs: ms(inputHoldLimit), ceilingMs: ms(inputHoldCeiling))
        switch reason {
        case nil: return nil
        case .gaveUp?: return "the reattach gave up"
        case .offline?: return "the Mac was offline and the link made no progress for \(inputHoldLimit) s"
        case .ceiling?: return "the terminal was unreachable for longer than \(inputHoldCeiling) s"
        }
        #else
        if gaveUp { return "the reattach gave up" }
        if let offlineSince, typedAt.contains(where: { now - max($0, offlineSince) >= inputHoldLimit }) {
            return "the Mac was offline for \(inputHoldLimit) s"
        }
        if typedAt.contains(where: { now - $0 >= inputHoldCeiling }) {
            return "the terminal was unreachable for longer than \(inputHoldCeiling) s"
        }
        return nil
        #endif
    }

    /// Drops every queued key, refuses input until the next attach, and tells the screen.
    private func dropDetachedInput(reason: String) {
        let bytes = input.reduce(0) { $0 + ($1.typed ? $1.bytes.count : 0) }
        let pastes = input.compactMap(\.paste)
        input.removeAll()
        reportHeldInput()
        // Only terminal replies were waiting: nothing the person typed was
        // lost, so typing goes on and the screen says nothing.
        guard bytes > 0 else { return }
        if !attached { refusingInput = true }
        log.notice("surface \(self.surface, privacy: .public): \(bytes, privacy: .public) typed bytes dropped (\(reason, privacy: .public))")
        handler?(.inputNotSent(bytes: bytes))
        pastes.forEach(pasteWasNotSent)
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

    /// The phone projects this terminal (``TerminalProjectingSession``).
    private var projectsLocally = false

    public func setProjectsLocally(_ projects: Bool) {
        projectsLocally = projects
    }

    /// The terminal is on screen in the foreground app (true), or it left
    /// (false: another tab, the grid, a sheet over it, the app in the
    /// background). Leaving releases the phone's size on the Mac at once, so
    /// the Mac's pane gets its own size back; coming back claims the last
    /// size again.
    public func setClaimsSize(_ claims: Bool) {
        guard claims != claimsSize else { return }
        claimsSize = claims
        claimGeneration &+= 1
        outbox.removeAll { if case .size = $0 { true } else { false } }
        if claims {
            macKeepsGrid = false
            if attached, let size = lastSize {
                log.notice("surface \(self.surface, privacy: .public): shown again, claiming \(size.columns, privacy: .public)x\(size.rows, privacy: .public)")
                enqueue(.size(columns: size.columns, rows: size.rows))
            }
            settleReclaimHold()
            armLiveness()
        } else {
            reclaimDeadline?.cancel()
            reclaimDeadline = nil
            stopLeaseRefresh()
            stopLiveness()
            if attached, sizeClaimed {
                log.notice("surface \(self.surface, privacy: .public): left the screen, releasing its size")
                releaseNow()
            }
            sizeClaimed = false
        }
    }

    public func stop() {
        gaveUpRetry?.cancel()
        gaveUpRetry = nil
        streamPosition = nil
        eventTask?.cancel()
        eventTask = nil
        historyPrefetch?.cancel()
        historyPrefetch = nil
        inbox?.close()
        inbox = nil
        outputPaused = false
        handler = nil
        reclaimDeadline?.cancel()
        reclaimDeadline = nil
        reclaimHold = TerminalReclaimHold()
        stopLeaseRefresh()
        // The Mac drops this attach (a tab cooled out of the warm set, or
        // gone). The size is released first and answered, so the Mac never
        // reads the close as a dropped link (which holds its grid for 30 s).
        if let client {
            // A claimed size, or a release still waiting behind another request.
            let release = attached && (sizeClaimed || releasesInFlight > 0
                || outbox.contains { if case .release = $0 { true } else { false } })
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
        if let old = replacing {
            replacing = nil
            Task { await old.close() }
        }
        dropInputLane()
        outbox.removeAll()
        input.removeAll()
        pasteNotSent.removeAll()
        typedSends.removeAll()
        echoDue = nil
        echoDueAckMs = nil
        tailProbe?.cancel()
        tailProbe = nil
        autoReattach?.cancel()
        autoReattach = nil
        autoReattaching = false
        stopLiveness()
        inputUnansweredSince = nil
    }

    /// An attach refused because the Mac does not know the surface (its
    /// error says "unknown surface N"), not for a field it sent.
    static func refusesSurface(_ error: String) -> Bool {
        error.hasPrefix("unknown surface")
    }

    /// Attaches again after a dropped link. A no-op while attached or
    /// attaching, before `start`, and after the surface ended.
    public func reconnect() {
        guard handler != nil, !attached, !ended else { return }
        // A first attach on a cold launch runs while the link pairs: its open can read "no
        // link" just before the link is served, and the link's own `reconnect()` of every
        // terminal landed here while that attach was still out and was dropped. The attach
        // then waited for a link that had come already: the terminal page drew its skeleton
        // for good (Aziz's TestFlight build, 2026-11-25). Remember it instead.
        if attaching {
            reconnectWhileAttaching = true
            return
        }
        if gaveUp {
            // A fresh round of retries, from the shortest delay.
            gaveUp = false
            attachRetries = 0
        }
        gaveUpRetry?.cancel()
        gaveUpRetry = nil
        handler?(.connection(connectionState))
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

    public var clearsHistory: Bool { true }

    /// The Mac's Clear Screen and Scrollback (`TerminalHandlers` "terminal.clear", the page
    /// menu's path: no fallback key): `clear-history {surface}` on the attach channel. The
    /// daemon erases the shell's rows above the prompt and the retained history, and every
    /// attached view, this one too, gets the same erase in its output. A full-screen app is
    /// left untouched, as on the Mac.
    public func clearHistory() async throws {
        guard attached, let client else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
        let surface = surface
        let reply = try await client.request("clear-history", params: ["surface": surface])
        if let error = Self.error(in: reply) {
            log.error("surface \(surface, privacy: .public): clear-history refused: \(error, privacy: .public)")
            throw LinkError(code: "clear-history", message: error)
        }
    }

    /// The reader scrolled up to the mirror's oldest row and the Mac has
    /// older ones (``historyRowsOmitted``): a second attach with
    /// ``historyChunkRows`` more rows of history (all of them when that many
    /// or fewer are left) replaces this one. The mirror resets and the
    /// screen keeps the reader's place (`TerminalReadingMark`), as for a
    /// reattach, but the connection stays attached throughout. One at a time;
    /// a no-op while a key is on its way (it must not be sent twice), and
    /// against a daemon without `attach-replay-history-rows-v1`.
    /// Returns whether the fetch was sent (its reset and replay follow).
    ///
    /// Against a daemon with `attach-replay-history-window-v1`, the mirror
    /// holds at most ``maxTailHistoryRows`` of the newest rows; past them it
    /// holds a window of ``historyWindowRows`` far above the screen
    /// (`replay_history_start`), moved up ``historyWindowStep`` rows per fetch until it holds
    /// line 1, so the phone never holds the Mac's whole history.
    @discardableResult
    public func loadOlderHistory() -> Bool {
        guard attached, !attaching, replacing == nil, !awaitingReplay, tailReplay, historyRowsOmitted > 0,
              inputInFlight == 0, let client else { return false }
        if windowReplay, historyWindowStart != nil
            || (historyAllowance ?? 0) + Self.historyChunkRows > Self.maxTailHistoryRows {
            // The window moves up a step: the rows read stay in it.
            historyWindowStart = max(0, historyRowsOmitted - Self.historyWindowStep)
        } else {
            guard let allowance = historyAllowance else { return false }
            historyAllowance = historyRowsOmitted <= Self.historyChunkRows ? nil : allowance + Self.historyChunkRows
        }
        log.notice("surface \(self.surface, privacy: .public): older history asked (\(self.historyRowsOmitted, privacy: .public) rows on the Mac, next \(self.historyRequestDescription, privacy: .public))")
        replacing = client
        Task { await attach() }
        return true
    }

    /// The daemon refused `terminal-find` (an older Mac, or a lane that does not list it): the
    /// screen searches its mirror for the rest of this session.
    private var findUnsupported = false

    /// `terminal-find {surface, query, ...}` on the attach channel: one page of matches in the
    /// terminal's whole history. Nil when the daemon has no such command.
    public func findPage(_ request: TerminalFindRequest) async throws -> TerminalFindPage? {
        // Settings → Terminal → Find in Whole History, off by default: off, the mirror searches itself.
        guard !findUnsupported, CmuxMobilePreferences.terminalHistoryFind() else { return nil }
        guard attached, let client else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
        var params = request.fields
        params["surface"] = surface
        let reply = try await client.request("terminal-find", params: params)
        do {
            return try TerminalFindPage.decode(reply)
        } catch let error as TerminalFindError where error.isUnsupported {
            log.notice("surface \(self.surface, privacy: .public): terminal-find not available: \(String(describing: error), privacy: .public)")
            findUnsupported = true
            return nil
        }
    }

    public var findMirror: TerminalFindMirror? {
        return TerminalFindMirror(omitted: historyRowsOmitted, skipped: historyRowsSkipped, windowRows: historyWindowRows)
    }

    /// Brings the history around `daemonRow` into the mirror: the newest rows down to it
    /// when it is within reach of a tail, else a window centered on it
    /// (`attach-replay-history-window-v1`).
    @discardableResult
    public func loadHistory(aroundDaemonRow daemonRow: Int, rowsFromBottom: Int) -> Bool {
        guard attached, !attaching, replacing == nil, !awaitingReplay, tailReplay,
              inputInFlight == 0, let client else { return false }
        if windowReplay, rowsFromBottom + Self.historyChunkRows > Self.maxTailHistoryRows {
            historyWindowStart = max(0, daemonRow - Self.historyWindowRows / 2)
        } else {
            historyWindowStart = nil
            let wanted = rowsFromBottom + Self.historyChunkRows / 4
            historyAllowance = wanted >= historyRowsOmitted + (historyAllowance ?? 0) ? nil : max(historyAllowance ?? 0, wanted)
        }
        log.notice("surface \(self.surface, privacy: .public): history for a find match asked (\(self.historyRequestDescription, privacy: .public))")
        replacing = client
        Task { await attach() }
        return true
    }

    public var historyWindowRows: Int? {
        historyWindowStart != nil && historyRowsSkipped > 0 ? Self.historyWindowRows : nil
    }

    /// The reader came down to the last row of the window far above the
    /// screen (``historyWindowRows``): the window moves a step toward the
    /// screen. Once it comes within its size of the screen the Mac sends the
    /// rows from its start down to the screen, and the mirror holds the
    /// newest rows again (at most twice the window). `toTheScreen` (the
    /// reader came up from the screen to the window): the newest rows at once.
    @discardableResult
    public func loadNewerHistory(toTheScreen: Bool) -> Bool {
        guard attached, !attaching, replacing == nil, !awaitingReplay, let start = historyWindowStart, historyRowsSkipped > 0,
              inputInFlight == 0, let client else { return false }
        if toTheScreen {
            historyWindowStart = nil
            historyAllowance = Self.maxTailHistoryRows
        } else {
            historyWindowStart = start + Self.historyWindowStep
        }
        log.notice("surface \(self.surface, privacy: .public): newer history asked (\(self.historyRowsSkipped, privacy: .public) rows below the window, next \(self.historyRequestDescription, privacy: .public))")
        replacing = client
        Task { await attach() }
        return true
    }

    /// The size a history fetch's attach claims in the setup's own write:
    /// the live attach's, when it claimed one and the phone asks for nothing
    /// else (no newer size, no size the Mac overruled). Nil: the attach
    /// waits for identify, as a reattach does.
    private var replacementAttachSize: (columns: Int, rows: Int)? {
        guard claimsSize, tailReplay, overruled == nil, pendingSize == nil, let live = attachedWithSize,
              let size = lastSize, size.columns == live.columns, size.rows == live.rows else { return nil }
        return live
    }

    // MARK: Fenced reattach (attach-identity-v1)

    /// The daemon takes `expected_generation` and `expected_terminal_id` on
    /// `attach-surface` and refuses an attach whose boot or terminal changed,
    /// before any stream or size lease.
    static let attachIdentityCapability = "attach-identity-v1"

    /// The Mac daemon as its last `identify` described it.
    struct KnownDaemon: Equatable {
        let capabilities: Set<String>
        let generation: String
    }

    /// This session's daemon, from the last attach's `identify`.
    private var knownDaemon: KnownDaemon?
    /// A fence was refused for something other than identity (a lane that
    /// refuses the fields): reattaches ask first for the rest of the session.
    private var fencedAttachOff = false
    /// The last fenced attach was refused: the next one asks first.
    private var fenceSkipOnce = false

    /// One fenced reattach: the size it claims, and the identity it names.
    struct FencedAttach {
        let size: (columns: Int, rows: Int)?
        let generation: String
        let terminalID: String
    }

    struct FencedAttachRefused: Error {
        let reason: String
    }

    /// A reattach that can go in the setup's write: the terminal has a public
    /// id, the daemon fences, and nothing about this attach needs the replies
    /// of the setup (a hybrid resume, a size the Mac overruled).
    private func fencedAttach() -> FencedAttach? {
        guard !fencedAttachOff, !fenceSkipOnce, everAttached || attachRetries > 0,
              let terminalID, terminalID.hasPrefix("term_"),
              let known = knownDaemon, known.capabilities.contains(Self.attachIdentityCapability),
              !(hybridWanted && hybridResume != nil), overruled == nil else { return nil }
        let size = claimsSize && known.capabilities.contains("attach-initial-size") ? (lastSize ?? pendingSize) : nil
        return FencedAttach(size: size, generation: known.generation, terminalID: terminalID)
    }

    /// The fenced `attach-surface`: what the attach after `identify` would
    /// send (size, history, a byte resume), plus the identity it expects.
    private func fencedAttachParams(_ fenced: FencedAttach) -> sending [String: Any] {
        var params: [String: Any] = ["surface": surface, "expected_generation": fenced.generation,
                                     "expected_terminal_id": fenced.terminalID]
        if let size = fenced.size {
            params["cols"] = size.columns
            params["rows"] = size.rows
        }
        if tailReplay {
            if windowReplay, let start = historyWindowStart {
                params["replay_history_rows"] = Self.historyWindowRows
                params["replay_history_start"] = start
            } else if let rows = historyAllowance {
                params["replay_history_rows"] = rows
            }
        }
        if !hybridWanted, let position = streamPosition,
           let known = knownDaemon, known.capabilities.contains(Self.terminalResumeCapability) {
            params["resume_offset"] = position.offset
            params["resume_generation"] = position.generation
            if known.capabilities.contains(Self.terminalResumeBoundedCapability) {
                params["resume_max_bytes"] = max(Self.minResumeBytes, lastReplayBytes ?? 0)
            }
        }
        return params
    }

    /// A refusal about the boot or the terminal (ask where it is, then attach),
    /// not about a field.
    nonisolated static func fenceRefusalIsIdentity(_ reason: String) -> Bool {
        reason.contains("attachment_generation_mismatch") || reason.contains("attachment_terminal_mismatch")
            || reason.contains("unknown surface")
    }

    /// The daemon an `identify` reply describes (nil: no boot generation).
    nonisolated static func knownDaemon(_ identify: Data) -> KnownDaemon? {
        guard let object = try? JSONSerialization.jsonObject(with: identify) as? [String: Any],
              let data = object["data"] as? [String: Any],
              let generation = data["generation"] as? String, !generation.isEmpty else { return nil }
        return KnownDaemon(capabilities: Set(capabilities(identify)), generation: generation)
    }

    /// `attach-surface` for this surface at `size`, with the history the
    /// next replay holds: the window far above the screen, or the newest
    /// ``historyAllowance`` rows (nil: all of them).
    private func historyAttachParams(size: (columns: Int, rows: Int)) -> sending [String: Any] {
        var params: [String: Any] = ["surface": surface, "cols": size.columns, "rows": size.rows]
        if windowReplay, let start = historyWindowStart {
            params["replay_history_rows"] = Self.historyWindowRows
            params["replay_history_start"] = start
        } else if let rows = historyAllowance {
            params["replay_history_rows"] = rows
        }
        return params
    }

    private var historyRequestDescription: String {
        if let start = historyWindowStart { return "window \(start)+\(Self.historyWindowRows)" }
        return "allowance \(historyAllowance.map(String.init) ?? "all")"
    }

    /// The most history ``requestHistoryRows(_:)`` asks for ahead of time.
    static let maxRequestedHistoryRows = 5 * historyChunkRows

    // MARK: History behind the screen

    /// Leo, 2026-11-22: "me personally interacting from [the Mac] directly
    /// scrolling interactivity percieved speed is actually just fine and i
    /// don't see anything off about it. so the phone side is clearly doing
    /// something off." The screen-first attach brought the screen alone, and
    /// a reader scrolling up hit its top at once: the fling stopped there and
    /// waited for a second attach over the link for every 2,000 rows. The Mac
    /// scrolls its own scrollback. So once the screen is live, the history
    /// follows by itself (``historyPrefetchDelay`` later, one fetch of up to
    /// ``prefetchHistoryRows`` rows, the same replacing attach a scroll to the
    /// top makes), and the reader scrolls through rows the phone holds.
    /// Older rows than that still come in chunks at the top.
    static let prefetchHistoryRows = maxTailHistoryRows
    /// After the attach is live (the first screen drawn and typing works),
    /// how long the history waits behind it.
    static let defaultHistoryPrefetchDelay: Duration = .milliseconds(300)
    /// nil: no prefetch (tests of the on-demand chunks).
    var historyPrefetchDelay: Duration? = DaemonTerminalSession.defaultHistoryPrefetchDelay
    /// The one prefetch of this session went out.
    private(set) var historyPrefetched = false
    private var historyPrefetch: Task<Void, Never>?

    /// The history behind a live screen-first attach, once per session.
    private func scheduleHistoryPrefetch() {
        guard let delay = historyPrefetchDelay, !historyPrefetched, historyPrefetch == nil,
              attached, tailReplay, historyRowsOmitted > 0, historyWindowStart == nil,
              let allowance = historyAllowance, allowance < Self.prefetchHistoryRows else { return }
        historyPrefetch = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.historyPrefetch = nil
            self.prefetchHistoryNow()
        }
    }

    private func prefetchHistoryNow() {
        guard !historyPrefetched, attached, tailReplay, historyRowsOmitted > 0, historyWindowStart == nil,
              let allowance = historyAllowance, allowance < Self.prefetchHistoryRows else { return }
        // A key on its way (it must not be sent twice), or another fetch or
        // attach out: look again after the same wait.
        // Or the last attach's replay is still on its way: its rows are not
        // the Mac's yet.
        guard !attaching, replacing == nil, !awaitingReplay, inputInFlight == 0, let client else { return scheduleHistoryPrefetch() }
        historyPrefetched = true
        let total = allowance + historyRowsOmitted
        // At most the tail a scroll could grow to (``maxTailHistoryRows``): past
        // it a scroll to the top moves the window (#43189), as before.
        historyAllowance = total <= Self.prefetchHistoryRows ? nil : Self.prefetchHistoryRows
        log.notice("surface \(self.surface, privacy: .public): history prefetched behind the screen (\(self.historyRowsOmitted, privacy: .public) rows on the Mac, allowance \(self.historyAllowance.map(String.init) ?? "all", privacy: .public))")
        replacing = client
        Task { await attach() }
    }

    /// A tab back from the warm set will put its reader back `rows` rows above
    /// the end: the next attach asks for that much history, in whole
    /// ``historyChunkRows`` (up to ``maxRequestedHistoryRows``), so the first
    /// replay holds the reader's rows instead of the screen alone and a
    /// second fetch.
    public func requestHistoryRows(_ rows: Int) {
        guard let allowance = historyAllowance, rows > allowance else { return }
        let chunks = (rows + Self.historyChunkRows - 1) / Self.historyChunkRows
        historyAllowance = max(allowance, min(Self.maxRequestedHistoryRows, chunks * Self.historyChunkRows))
    }

    /// Sends one pan's frames to the Mac (`phone-frames`); the coordinator sets it.
    /// It returns when the line went out or could not.
    public var scrollFramesSink: (@MainActor (TerminalPanFrames) async -> Void)?
    /// Pan lines on their way: past ``maxScrollFramesInFlight`` a pan is dropped, never queued.
    private var scrollFramesInFlight = 0
    static let maxScrollFramesInFlight = 2

    /// Sends painted redraws to the Mac (`phone-frames` `paint`); the coordinator sets it.
    public var paintSink: (@MainActor ([TerminalPaintTally.Sample], String?) async -> Void)?
    private var paintInFlight = false

    public func reportPaint(_ samples: [TerminalPaintTally.Sample]) {
        // One report on its way at a time: a report while one is out is dropped, never queued.
        guard let sink = paintSink, !paintInFlight, !samples.isEmpty else { return }
        paintInFlight = true
        let program = programName
        Task { [weak self] in
            await sink(samples, program)
            self?.paintInFlight = false
        }
    }

    public func reportScrollFrames(_ pan: TerminalPanFrames) {
        guard let sink = scrollFramesSink, scrollFramesInFlight < Self.maxScrollFramesInFlight else { return }
        guard pan.intervalsMs.count >= TerminalPanFrames.minFrames else { return }
        var pan = pan
        pan.program = programName
        scrollFramesInFlight += 1
        Task { [weak self] in
            await sink(pan)
            self?.scrollFramesInFlight -= 1
        }
    }

    /// The size state and own participant of an attach reply (shared sizing).
    /// Whether an `attach-surface` reply resumed the byte stream exactly (`resume: "exact"`,
    /// `terminal-resume-v1`): its only event is the missed bytes, with no replay.
    nonisolated static func resumedExactly(_ reply: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return false }
        return data["resume"] as? String == "exact"
    }

    nonisolated static func attachSizing(_ reply: Data) -> (TerminalSizeState?, String?) {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return (nil, nil) }
        return (TerminalSizeState.decode(data["size_state"]), data["participant"] as? String)
    }

    // MARK: Attach

    private func attach() async {
        guard !attaching else { return }
        // Whoever attaches now (a new link, Retry, a key) supersedes a pending self-reattach.
        autoReattach?.cancel()
        autoReattach = nil
        attaching = true
        reconnectWhileAttaching = false
        awaitingReplay = false
        defer { attaching = false }
        // A history fetch: the attach it replaces is live on this daemon.
        let replacement = replacing != nil
        do {
            let client = try await open()
            guard handler != nil else { return }
            self.client = client
            await client.start()
            // A reattach (or a retry) first asks where the terminal is: a Mac
            // daemon that restarted numbers its surfaces again, and the old
            // number may now name another terminal (defect 2 of
            // verify/transport-verify-20261019.md). A history fetch does not:
            // the attach it replaces is still live on the same daemon, so the
            // surface number is current (one round trip less per fetch).
            // A daemon that fences attaches (`attach-identity-v1`) needs no
            // question either: the attach names the boot and the terminal it
            // expects and goes in the setup's write, and the daemon refuses it,
            // before any stream, if either changed (then this asks, below).
            // Three round trips become one (Leo, 2026-11-17: "the gosh darn
            // loading of everything needs to be FASTER").
            let fenced = replacement ? nil : fencedAttach()
            fenceSkipOnce = false
            if fenced == nil, let terminalID, !replacement, everAttached || attachRetries > 0 {
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
            let linkProgress = linkProgress
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
            let resumeFrom = hybridWanted ? hybridResume : nil
            // A reattach in bytes mode from a known position (`terminal-resume-v1`). Not a
            // history fetch: it replaces the mirror with more rows on purpose.
            let bytesFrom = !hybridWanted && !replacement ? streamPosition : nil
            let resumeAlternate = (resumeFrom != nil || bytesFrom != nil) && isAlternateScreen
            let bytesResume = bytesFrom != nil
            eventTask = Task.detached { [weak self] in
                var parser = DaemonTerminalEventParser(surface: surface, hybridResume: resumeFrom, alternate: resumeAlternate, bytesResume: bytesResume)
                for await line in events {
                    // Bytes heard from the Mac: the link is moving.
                    linkProgress?.progressed()
                    await inbox.push(parser.parse(line))
                }
                // After the batches already queued (the main queue is FIFO).
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.channelEnded(client) }
                }
            }
            // A fetch of older or newer rows replaces a live attach on this
            // same daemon, at the size that attach claims: the attach goes in
            // the setup's write (one round trip instead of two).
            let quickSize = replacement ? replacementAttachSize : nil
            attachedWithSize = nil
            sizeClaimed = false
            sizing.clear()
            lastActivityNote = nil
            // The mirror is not reset yet: a reattach that fails (a Mac host
            // that just restarted answers "unknown surface" for a moment) keeps
            // the last frame on screen under the reconnecting badge, instead
            // of a blank screen with an error line (termqa D3). The replay's
            // events wait in `heldEvents` until the attach is confirmed.
            heldEvents = []
            // One write: the client info (it opts into the size lease), identify
            // and, replacing a live attach, the attach.
            var info: [String: Any] = clientInfo
            info["capabilities"] = Self.capabilities(agentCLIHybrid: hybridWanted)
            // Which attach the Mac sends (byte stream, or lean frames at most one per 100 ms):
            // the setting this phone holds, read in its log beside the link's path and rtt.
            log.info("attach agent_cli_hybrid=\(Self.agentCLIHybridEnabled(self.agentCLIHybridDefaults), privacy: .public) wanted=\(self.hybridWanted, privacy: .public)")
            var batch: [(cmd: String, params: [String: Any])] = [(cmd: "set-client-info", params: info), (cmd: "identify", params: [:])]
            // A first attach on screen sends the grid the page measured with
            // the attach, in the same write (TerminalAttachPlan): the Mac
            // answers with the replay at that grid one round trip after the
            // start instead of two. Its events wait from now on.
            let plan = TerminalAttachPlan.plan(firstAttach: quickSize == nil && !everAttached && attachRetries == 0, claimsSize: claimsSize,
                                               size: lastSize ?? pendingSize, resumes: hybridResume != nil || bytesFrom != nil)
            var pipelinedSize: (columns: Int, rows: Int)?
            if case .pipelined(let columns, let rows) = plan {
                pipelinedSize = (columns, rows)
                var params: [String: Any] = ["surface": surface, "cols": columns, "rows": rows]
                if let historyRows = historyAllowance { params["replay_history_rows"] = historyRows }
                batch.append((cmd: "attach-surface", params: params))
            } else if let quickSize {
                batch.append((cmd: "attach-surface", params: historyAttachParams(size: quickSize)))
            }
            // Fenced reattaches name the boot and terminal identity in the same
            // setup write. They are mutually exclusive with the requests above.
            if let fenced { batch.append((cmd: "attach-surface", params: fencedAttachParams(fenced))) }
            let setup = await client.requests(batch)
            let identify = setup.dropFirst().first.flatMap { try? $0.get() }
            knownDaemon = identify.flatMap(Self.knownDaemon)
            // The pipelined attach's reply. A link that failed under it is a
            // failed attach (the retry below); a refusal falls back to the
            // attach in series, with what identify listed.
            let pipelined: (reply: Data, columns: Int, rows: Int)?
            if let pipelinedSize, setup.count > 2 {
                pipelined = (try setup[2].get(), pipelinedSize.columns, pipelinedSize.rows)
            } else {
                pipelined = nil
            }
            let quickReply = quickSize == nil ? nil
                : setup.dropFirst(2).first.flatMap { try? $0.get() }.flatMap { Self.error(in: $0) == nil ? $0 : nil }
            var fencedReply: Data?
            if let fenced {
                let slot = setup.dropFirst(2 + (pipelinedSize == nil && quickSize == nil ? 0 : 1)).first
                if let slot {
                    let reply = try slot.get()
                    if let error = Self.error(in: reply) { throw FencedAttachRefused(reason: error) }
                    fencedReply = reply
                }
            }
            // What a refused quick attach sent first is not the replay.
            if quickSize != nil, quickReply == nil { heldEvents = [] }
            // Hidden: attach without a size, so the attach claims none.
            let initialSize = claimsSize && (identify.map(Self.acceptsInitialSize) ?? false)
            shortLease = identify.map { Self.lists(Self.shortSizeLeaseCapability, $0) } ?? false
            leased = shortLease || (identify.map { Self.lists(Self.sizeLeaseCapability, $0) } ?? false)
            sharedSizing = identify.map { Self.lists(Self.sharedSizingCapability, $0) } ?? false
            sendKeys = identify.map { Self.lists(Self.sendKeyCapability, $0) } ?? false
            // A daemon that does not list the hybrid stream would refuse a resume's fields
            // (one older than it, or one this phone reached after a Mac update rolled back).
            let hybridResumable = identify.map { Self.lists(Self.agentCLIHybridCapability, $0) } ?? false
            tailReplay = identify.map { Self.lists(Self.replayHistoryRowsCapability, $0) } ?? false
            windowReplay = tailReplay && !windowRefused
                && (identify.map { Self.lists(Self.replayHistoryWindowCapability, $0) } ?? false)
            if !windowReplay { historyWindowStart = nil }
            pasteSubmit = identify.map { Self.lists(Self.pasteSubmitCapability, $0) } ?? false
            typedSubmit = identify.map { Self.lists(Self.typedSubmitCapability, $0) } ?? false
            // A daemon that does not list it would refuse the resume fields.
            let resumable = identify.map { Self.lists(Self.terminalResumeCapability, $0) } ?? false
            let resumeBounded = identify.map { Self.lists(Self.terminalResumeBoundedCapability, $0) } ?? false
            let bytesResumeFrom = resumable ? bytesFrom : nil
            // Attached: this daemon's answer (or its silence: an older one) settles the composer's
            // waiting Sends. One that takes no keys gives them up; they never went out.
            identified = true
            #if canImport(CmuxMobileLinkFFI)
            if !composerOutbox.setCapabilities(capabilities: identify.map(Self.capabilities) ?? []) { giveUpComposerSends() }
            #endif
            // `attach-surface` with this view's size (if any) and history
            // allowance. A lane that refuses the allowance (a Mac app older
            // than its daemon) gets the same attach without it.
            func attachSurface(_ size: (columns: Int, rows: Int)?) async throws -> Data {
                // Each request gets its own literal: a dictionary sent to the
                // client actor is never touched again here (Swift 6 regions).
                func send(historyRows: Int?) async throws -> Data {
                    // Settings → Transport → Agent CLI Screen Changes: a reattach resumes
                    // the hybrid stream from the frame this mirror drew.
                    if hybridWanted, hybridResumable, let resume = hybridResume {
                        var params: [String: Any] = ["surface": surface, "hybrid_stream": resume.stream, "hybrid_frame": resume.frame]
                        if let size {
                            params["cols"] = size.columns
                            params["rows"] = size.rows
                        }
                        if let historyRows {
                            params["replay_history_rows"] = historyRows
                            // The window too (attach-replay-history-window-v1).
                            if windowReplay, let start = historyWindowStart { params["replay_history_start"] = start }
                        }
                        return try await client.request("attach-surface", params: params)
                    }
                    // A window far above the screen (attach-replay-history-window-v1).
                    if let rows = historyRows, windowReplay, let start = historyWindowStart {
                        if let size {
                            return try await client.request("attach-surface", params: ["surface": surface, "cols": size.columns, "rows": size.rows,
                                                                                       "replay_history_rows": rows, "replay_history_start": start])
                        }
                        return try await client.request("attach-surface", params: ["surface": surface, "replay_history_rows": rows,
                                                                                   "replay_history_start": start])
                    }
                    // In bytes mode from a known position: the missed bytes, or (a gap) the
                    // same replay as below.
                    if let position = bytesResumeFrom {
                        var params: [String: Any] = ["surface": surface, "resume_offset": position.offset, "resume_generation": position.generation]
                        if resumeBounded { params["resume_max_bytes"] = max(Self.minResumeBytes, lastReplayBytes ?? 0) }
                        if let size {
                            params["cols"] = size.columns
                            params["rows"] = size.rows
                        }
                        if let historyRows {
                            params["replay_history_rows"] = historyRows
                            if windowReplay, let start = historyWindowStart { params["replay_history_start"] = start }
                        }
                        return try await client.request("attach-surface", params: params)
                    }
                    switch (size, historyRows) {
                    case let (size?, rows?):
                        return try await client.request("attach-surface", params: ["surface": surface, "cols": size.columns, "rows": size.rows, "replay_history_rows": rows])
                    case let (size?, nil):
                        return try await client.request("attach-surface", params: ["surface": surface, "cols": size.columns, "rows": size.rows])
                    case let (nil, rows?):
                        return try await client.request("attach-surface", params: ["surface": surface, "replay_history_rows": rows])
                    case (nil, nil):
                        return try await client.request("attach-surface", params: ["surface": surface])
                    }
                }
                if tailReplay, windowReplay, historyWindowStart != nil {
                    let reply = try await send(historyRows: Self.historyWindowRows)
                    guard let error = Self.error(in: reply), error.contains("replay_history_start") else { return reply }
                    // A lane that refuses the window (a Mac app older than
                    // its daemon): the newest rows in chunks, as before, for
                    // the rest of this session, so line 1 is still reached.
                    windowReplay = false
                    windowRefused = true
                    historyWindowStart = nil
                    historyAllowance = Self.maxTailHistoryRows
                }
                guard tailReplay, let rows = historyAllowance else { return try await send(historyRows: nil) }
                let reply = try await send(historyRows: rows)
                guard let error = Self.error(in: reply), error.contains("replay_history_rows") else { return reply }
                tailReplay = false
                return try await send(historyRows: nil)
            }
            // A pipelined attach refused for its surface ("unknown surface": a
            // Mac host that just restarted) failed as an attach, not for its
            // grid or fields: the attach in series would hear the same. It goes
            // to the retry like any failed attach, one attach a try, keeping
            // the last frame (termqa D3).
            if let pipelined, let error = Self.error(in: pipelined.reply), Self.refusesSurface(error) {
                throw LinkError(code: "attach", message: error)
            }
            // The Mac took the pipelined attach: its replay is already held.
            let pipelinedReply = pipelined.flatMap { Self.error(in: $0.reply) == nil ? $0 : nil }
            if pipelined != nil, pipelinedReply == nil { heldEvents = [] }
            // With the size in the attach the Mac builds the replay at that size
            // once; attached first and resized after, it reset the mirror and
            // replayed the whole history a second time (user report 2026-10-14).
            var reply: Data
            if let fencedReply, let fenced {
                // Attached in the setup's write, at the size it claimed (if any).
                reply = fencedReply
                if let size = fenced.size {
                    lastSize = size
                    attachedWithSize = size
                    lastClaimAt = .now
                }
            } else if let pipelined = pipelinedReply {
                // The Mac took the attach with the phone's grid. A daemon that
                // does not list attach-initial-size ignored the grid: the
                // resize after the attach claims it, as an attach in series does.
                // The grid went out on screen: a page hidden since still
                // holds the size the attach carried, and releases it below.
                reply = pipelined.reply
                if identify.map(Self.acceptsInitialSize) ?? false {
                    lastSize = lastSize ?? (pipelined.columns, pipelined.rows)
                    attachedWithSize = (pipelined.columns, pipelined.rows)
                    lastClaimAt = .now
                }
            } else if let quickReply, let quickSize {
                // A refused quick attach (a lane that refuses a field) takes the
                // path below, which knows each refusal.
                reply = quickReply
                attachedWithSize = quickSize
            } else if initialSize, everAttached, let size = lastSize ?? pendingSize, let overruled,
               overruled.asked.columns == size.columns, overruled.asked.rows == size.rows,
               overruled.mac.columns <= size.columns, overruled.mac.rows <= size.rows {
                // The Mac kept its own size for this request last time, and it
                // fits in this phone's grid: attach at that size (no PTY
                // resize), and do not ask again. A larger Mac grid is never
                // claimed: the phone renders into its own grid, so the daemon
                // must know the phone's real size (a wider PTY overprinted
                // and cut every row, 2026-10-23).
                log.notice("surface \(self.surface, privacy: .public): reattach at the Mac's \(overruled.mac.columns, privacy: .public)x\(overruled.mac.rows, privacy: .public) (asked \(size.columns, privacy: .public)x\(size.rows, privacy: .public) was overruled)")
                reply = try await attachSurface((overruled.mac.columns, overruled.mac.rows))
                if Self.error(in: reply) != nil {
                    reply = try await attachSurface(nil)
                } else {
                    attachedWithSize = size
                    lastClaimAt = .now
                }
            } else if initialSize, let size = lastSize ?? pendingSize {
                reply = try await attachSurface(size)
                if Self.error(in: reply) != nil {
                    // A policy that does not pass the size: attach without it.
                    reply = try await attachSurface(nil)
                } else {
                    lastSize = size
                    attachedWithSize = size
                    lastClaimAt = .now
                }
            } else {
                reply = try await attachSurface(nil)
            }
            if let error = Self.error(in: reply) { throw LinkError(code: "attach", message: error) }
            guard self.client === client else { heldEvents = nil; return }
            let (sizeState, participant) = Self.attachSizing(reply)
            sizing.apply(sizeState, selfParticipant: participant)
            noteHostGridOwner()
            // The replay rebuilds the screen and scrollback. The reset also
            // tells the screen where the Mac's screen starts in its taller
            // mirror (TerminalRowShift).
            // The alternate screen is not touched here: the replay's
            // `vt-state` says its own final state before its rows (held or
            // still coming). Set to the primary screen first, a reattach to a
            // TUI left TUI mode and came back: the page showed the empty
            // primary screen with nothing held over it (termfix-r13 D2, `top`:
            // blank for ~170 ms, then half drawn).
            // Hidden and holding the Mac's grid, the reset and the replay
            // after it are held too: what was held before is superseded.
            // A resumed agent CLI stream (`agent-cli-hybrid-v1`) applies its first frame on
            // the screen this mirror holds: no reset, or the frame would draw on a blank one.
            let resumesHybrid = heldEvents?.contains { event in
                if case .hybridFrame(_, _, resumed: true) = event { return true }
                return false
            } ?? false
            // An exact byte resume (`terminal-resume-v1`): the Mac sent only what this mirror
            // missed, as one `output`, so the screen and its history stay as they are.
            let resumesBytes = bytesResumeFrom != nil && Self.resumedExactly(reply)
            log.notice("surface \(self.surface, privacy: .public): attach resume=\(resumesBytes ? "exact" : bytesResumeFrom != nil ? "gap" : resumesHybrid ? "hybrid" : "none", privacy: .public)")
            if !resumesBytes { streamPosition = nil }
            macKeepsGrid = false
            if !resumesHybrid, !resumesBytes {
                log.notice("surface \(self.surface, privacy: .public): mirror reset cause=\(self.everAttached ? "reattach" : "attach", privacy: .public) size=\(self.attachedWithSize.map { "\($0.columns)x\($0.rows)" } ?? "-", privacy: .public)")
                hybridResume = nil
                reclaimHold.restart(alternate: isAlternateScreen)
                show(.output(TerminalReclaimHold.reset))
                // The reply often lands before its own `vt-state` (that line is
                // decoded off the main actor): until the replay is applied, the
                // rows the Mac left out are the last attach's. A resumed stream
                // replays no history, so nothing is awaited.
                awaitingReplay = true
            }
            let held = heldEvents ?? []
            heldEvents = nil
            for event in held { apply(event) }
            attachRetries = 0
            // Keys held past the limit (the app was suspended) are dropped and said before
            // the screen hears `.attached`, which forgets a held composer send.
            expireInput()
            attached = true
            settleReclaimHold()
            refusingInput = false
            everAttached = true
            // The held keys go now (``drainInput()``): nothing is pending any more.
            reportHeldInput()
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
            if let old = replacing {
                // The new attach holds the screen and the size now: the old
                // one releases its size (the same size: no PTY resize) and
                // closes, so the Mac never reads it as a dropped link.
                replacing = nil
                let surface = surface
                Task {
                    _ = try? await Self.within(.seconds(2)) {
                        try await old.request("release-surface-size", params: ["surface": surface])
                    }
                    await old.close()
                }
            }
            autoReattaching = false
            drain()
            drainInput()
            openInputLane(for: client)
            armLiveness()
            scheduleHistoryPrefetch()
        } catch let refused as FencedAttachRefused {
            // The Mac restarted (another boot), the terminal moved to another
            // surface, or the lane refused a field: nothing streamed. Attach
            // again at once, asking where the terminal is first; a refusal
            // that is not about identity turns the fence off for this session.
            heldEvents = nil
            log.notice("surface \(self.surface, privacy: .public): fenced attach refused (\(refused.reason, privacy: .public)): resolving first")
            fenceSkipOnce = true
            if !Self.fenceRefusalIsIdentity(refused.reason) { fencedAttachOff = true }
            if let client = self.client { self.client = nil; Task { await client.close() } }
            eventTask?.cancel()
            eventTask = nil
            inbox?.close()
            inbox = nil
            Task { [weak self] in await self?.attach() }
        } catch {
            heldEvents = nil
            lastError = Self.diagnostic(error)
            log.error("attach surface \(self.surface): \(String(describing: error), privacy: .public)")
            if let old = replacing {
                // A failed fetch of older rows: the old attach no longer
                // feeds the screen, so this is a dropped link, retried below.
                replacing = nil
                attached = false
                Task { await old.close() }
                dropInputLane()
                stopLeaseRefresh()
                markInputDetached()
                draining = false
                if handler != nil, !ended { handler?(.connection(connectionState)) }
            }
            if Self.waitsForTheLink(error) {
                // An attach found no link: the link is down, and its return
                // reattaches every session (`LiveCoordinator` calls `reconnect()`).
                // Wait for it, "Reattaching…" with keys held, never into the
                // retries' "Can't reach" with Send refused. Any attach, not only a
                // self-reattach: back from minutes away, a tab's attach ran while
                // the link still redialed, spent its 16 s of retries on "no link"
                // and gave up (Send refused, keys dropped) before the link was back.
                // A link that stays down is the Mac's offline bound
                // (`setMacOffline`, `inputHoldLimit`), not this attach's to call.
                autoReattaching = false
                attachRetries = 0
                if let client = self.client { self.client = nil; Task { await client.close() } }
                if handler != nil, !ended { handler?(.connection(connectionState)) }
                // The link came while this attach was out: attach on it now (after this
                // attach's `defer`), not on a return that already happened.
                if reconnectWhileAttaching, handler != nil, !ended {
                    reconnectWhileAttaching = false
                    Task { [weak self] in self?.reconnect() }
                }
                return
            }
            if attachRetries < reattachBackoff.count, handler != nil, !ended {
                // Keep the last frame and try again (bounded backoff). A first
                // attach too: a fresh session (a tab back from the warm set, a cold
                // launch) whose link blipped gave up at once and wrote the error
                // over its cached frame (Leo's phone on LTE, 2026-11-12).
                let delay = reattachBackoff[attachRetries]
                attachRetries += 1
                if let client = self.client { self.client = nil; Task { await client.close() } }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    self?.reconnect()
                }
                return
            }
            // The failed attach's channel closes now, not at the next reconnect.
            // This applies to the first attach too: Retry must not retain a daemon
            // client or event reader from the failed attempt.
            if let client = self.client { self.client = nil; Task { await client.close() } }
            eventTask?.cancel()
            eventTask = nil
            inbox?.close()
            inbox = nil
            // Retries ran out. Nothing is written into the terminal: transport
            // words ("[daemon channel closed]") are not the Mac's output, and bytes
            // on the stream read as live content (the page dropped its cached
            // frame for them and saved the blank page over it). The state says
            // it instead: the composer's quiet line with Retry, and a keystroke
            // tries again.
            gaveUp = true
            scheduleGaveUpRetry()
            // Keys held for this reattach are dropped now, and the screen says so.
            expireInput()
            handler?(.connection(connectionState))
        }
    }

    /// The channel ended. After `detached` that is the end; otherwise the
    /// session attaches again by itself (``scheduleAutoReattach(_:)``), or
    /// when a new link calls ``reconnect()``, whichever comes first.
    private func channelEnded(_ client: DaemonClient) {
        guard self.client === client else { return }
        self.client = nil
        dropInputLane()
        attached = false
        stopLeaseRefresh()
        markInputDetached()
        draining = false
        stopLiveness()
        guard handler != nil, !ended else { return }
        if resyncAfterClose {
            // An agent CLI frame failed: attach again at once, for a keyframe or bytes.
            resyncAfterClose = false
            reconnect()
            return
        }
        handler?(.connection(connectionState))
        // Not only when a new link comes: the link may be fine (the daemon
        // closed this channel), and then nothing else would ever reattach.
        scheduleAutoReattach("attach channel ended")
    }

    /// One event line from the daemon channel, decoded on the main actor
    /// (tests; the attach stream decodes off the main actor).
    func handle(_ line: Data) {
        for event in lineParser.parse(line) { apply(event) }
    }

    private func apply(_ event: DaemonTerminalInbound) {
        switch event {
        case .output(let data):
            keyEchoed()
            show(.output(data))
        case .stamped(let seq, let receivedMs):
            show(.paintMark(seq: seq, receivedMs: receivedMs))
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
                show(.hostGrid(columns: columns, rows: rows))
            }
            // The Mac answered a size other than the one asked for (another
            // view of this terminal, the Mac's own window, sets the grid): the
            // request was overruled. A reattach then keeps the Mac's size
            // instead of resizing its PTY to the phone's grid and back, which
            // made an inline TUI (Codex) redraw its whole transcript twice
            // over the link (termqa D4/D8).
            // Hidden, the phone asks for nothing: a grid then is not an answer.
            if attached, claimsSize, let asked = lastSize, let columns = reportedColumns,
               asked.columns != columns || asked.rows != rows {
                overruled = Overruled(asked: asked, mac: (columns, rows))
            } else if attached, let asked = lastSize, asked.columns == reportedColumns, asked.rows == rows {
                overruled = nil
            }
        case .historyRowsOmitted(let rows):
            historyRowsOmitted = rows
            awaitingReplay = false
            scheduleHistoryPrefetch()
        case .historyRowsSkipped(let rows):
            historyRowsSkipped = rows
            if rows == 0, historyWindowStart != nil {
                // The window came within its size of the screen: the Mac sent
                // the rows from its start down (at most twice the window), and
                // the mirror holds the newest rows again.
                historyWindowStart = nil
                historyAllowance = 2 * Self.historyWindowRows
            }
        case let .hybridFrame(stream, frame, _):
            hybridResume = (stream, frame)
            // Cells, not the byte stream: no byte offset describes this screen.
            streamPosition = nil
        case .streamPosition(let position):
            streamPosition = position
        case .replayBytes(let bytes):
            lastReplayBytes = bytes
        case .hybridFallback(let reason):
            // The screen may be behind the Mac's: never resume from it.
            hybridResume = nil
            hybridFallbacks += 1
            log.error("surface \(self.surface, privacy: .public): agent CLI frame not drawn (\(reason, privacy: .public)): \(self.hybridFallbacks < 2 ? "full resync" : "bytes mode", privacy: .public)")
            guard let client, !resyncAfterClose else { break }
            resyncAfterClose = true
            Task { await client.close() }
        case .resetMirror(let alternate):
            // A `resized` replay holds the whole history, unless it names the
            // rows it left out (the next event). Either way its rows reach the
            // screen: a window far above it is numbered again by the reflow,
            // and the newest rows of its size come instead.
            historyRowsOmitted = 0
            historyRowsSkipped = 0
            awaitingReplay = false
            if historyWindowStart != nil {
                historyWindowStart = nil
                historyAllowance = Self.historyWindowRows
            }
            log.notice("surface \(self.surface, privacy: .public): mirror reset cause=resized-event (rows \(self.reportedRows ?? -1, privacy: .public), last size asked \(self.lastSize.map { "\($0.columns)x\($0.rows)" } ?? "-", privacy: .public))")
            setAlternate(alternate)
            show(.output(TerminalReclaimHold.reset))
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

    /// What a terminal whose attach retries ran out says (the composer's
    /// notice and quiet line), never the transport's error text.
    nonisolated static func unreachableMessage(_ mac: String?) -> String {
        let name = mac.flatMap { $0.isEmpty ? nil : $0 } ?? "your Mac"
        return "Can't reach this terminal on \(name). It reconnects on its own."
    }

    /// Writes a line into the terminal itself: only for facts about the
    /// terminal (its process exited, the Mac closed it, the daemon detached
    /// it), never for the connection to it. Transport states travel as
    /// `.connection` events (a quiet line by the composer).
    /// It goes after whatever the reclaim hold has, in stream order.
    private func emitText(_ text: String) {
        releaseReclaimHold()
        handler?(.output(Data(text.utf8)))
    }

    /// An event for the screen, through the reclaim hold: hidden, the Mac's
    /// own grid and what follows it wait there (`TerminalReclaimHold`).
    ///
    /// On screen too, the phone never draws a grid it did not ask for while
    /// its claim may still bring its own back: a grid other than the phone's
    /// (its lease ended over a slow link, a reattach replayed the Mac's grid,
    /// a claim not answered yet) starts the same hold, the phone claims its
    /// grid again at once, and the hold shows what it has only when the Mac
    /// keeps its grid past ``reclaimWait``.
    private func show(_ event: TerminalSessionEvent) {
        let phoneGrid = lastSize.map { TerminalReclaimHold.Grid(columns: $0.columns, rows: $0.rows) }
        // Projected, the primary screen shows the Mac's own grid re-wrapped:
        // nothing to hold back. A hidden full-screen app still waits for the
        // phone's grid, so a return never shows it stretched.
        let projectsPrimary = projectsLocally && !isAlternateScreen
        var claims = claimsSize || projectsPrimary
        var unwanted = false
        if case .hostGrid(let columns, let rows) = event, let phoneGrid {
            if phoneGrid == TerminalReclaimHold.Grid(columns: columns, rows: rows) {
                macKeepsGrid = false
            } else if claimsSize, !projectsPrimary, !macKeepsGrid, !reclaimHold.isHolding, client != nil {
                // Held as if hidden: the claim below answers it. Only with
                // a channel (attached, or replaying an attach that then
                // settles the hold): nothing else could end the hold.
                claims = false
                unwanted = true
            }
        }
        let wasHolding = reclaimHold.isHolding
        let events = reclaimHold.take(event, claims: claims, phoneGrid: phoneGrid, alternate: isAlternateScreen)
        if wasHolding != reclaimHold.isHolding {
            log.notice("surface \(self.surface, privacy: .public): \(wasHolding ? "reclaim hold ended" : unwanted ? "shown: holding a grid the phone did not ask for" : "hidden: holding the Mac's grid", privacy: .public)")
            if wasHolding {
                reclaimDeadline?.cancel()
                reclaimDeadline = nil
            } else if unwanted, attached {
                claimAgain()
                armReclaimDeadline()
            }
        }
        deliver(events)
    }

    /// On screen with a grid the phone did not ask for: its size again, at
    /// once (not behind the outbox), unless a size is already on its way.
    /// The same size renews the lease and resizes nothing.
    private func claimAgain() {
        guard attached, replacing == nil, let client, let size = lastSize else { return }
        // A size already queued or on its way answers the same grid (an
        // attach's replay can land just after the attach queued its size).
        guard !(draining && drainingSize),
              !outbox.contains(where: { if case .size = $0 { true } else { false } }) else { return }
        // A claim sent moments ago is still being answered; the hold's deadline covers it.
        if let lastClaimAt, ContinuousClock.now - lastClaimAt < claimAnswerWindow { return }
        log.notice("surface \(self.surface, privacy: .public): the Mac sent a grid the phone did not ask for, claiming \(size.columns, privacy: .public)x\(size.rows, privacy: .public) again")
        sizeClaimed = true
        startLeaseRefresh()
        let surface = surface
        lastClaimAt = .now
        reclaimsSent += 1
        let released = releaseWritten
        Task {
            await released?.value
            _ = try? await client.request("resize-surface", params: ["surface": surface, "cols": size.columns, "rows": size.rows])
        }
    }

    /// Releases this view's size now, not behind the outbox: a request there
    /// waits for the answer to the one before it, which comes back behind
    /// the terminal's output, and the app may be suspended by then. The
    /// daemon runs one connection's requests in order, so the release still
    /// lands after any size sent before it. A link that fails under it
    /// leaves the size to the Mac's lease.
    private func releaseNow() {
        guard attached, replacing == nil, let client else {
            enqueue(.release)
            return
        }
        let surface = surface
        releasesInFlight += 1
        // Written first, in order (`submit` returns once the line is on the
        // channel); the answer is read after.
        let written = Task { try await client.submit("release-surface-size", params: ["surface": surface]) }
        releaseWritten = Task { _ = try? await written.value }
        Task { [weak self] in
            defer { self?.releasesInFlight -= 1 }
            do {
                let reply = try await client.reply(to: try await written.value)
                if let error = Self.error(in: reply) {
                    log.error("release-surface-size failed: \(error, privacy: .public)")
                }
            } catch {
                log.notice("surface \(surface, privacy: .public): release-surface-size not answered (\(LinkController.reason(error), privacy: .public)); the Mac's lease ends the size")
            }
        }
    }

    /// Shows what the reclaim hold has, in order (`from`: the Mac's grid
    /// now, see `TerminalReclaimHold.release(from:)`).
    private func releaseReclaimHold(from grid: TerminalReclaimHold.Grid? = nil) {
        reclaimDeadline?.cancel()
        reclaimDeadline = nil
        let events = reclaimHold.release(from: grid)
        guard !events.isEmpty else { return }
        log.notice("surface \(self.surface, privacy: .public): reclaim hold released, \(events.count, privacy: .public) events shown")
        deliver(events)
    }

    /// Shown with the Mac's grid held. The Mac already at the phone's grid
    /// (no resize will answer the claim): what was held shows now.
    /// Otherwise, once attached, the claim has its deadline.
    private func settleReclaimHold() {
        guard claimsSize, reclaimHold.isHolding else { return }
        if let size = lastSize, reportedColumns == size.columns, reportedRows == size.rows {
            releaseReclaimHold(from: TerminalReclaimHold.Grid(columns: size.columns, rows: size.rows))
        } else if attached {
            armReclaimDeadline()
        }
    }

    /// Shown and attached with the Mac's grid held: the claim has
    /// `reclaimWait` to bring the phone's grid back (the Mac's policy may
    /// keep its own grid); then what was held shows.
    private func armReclaimDeadline() {
        reclaimDeadline?.cancel()
        let wait = reclaimWait
        reclaimDeadline = Task { [weak self] in
            // An intentional, bounded deadline (the claim's answer), not a
            // synchronization wait.
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, self.claimsSize, self.attached else { return }
            self.reclaimDeadline = nil
            // The Mac keeps its grid: later changes show as they come.
            self.macKeepsGrid = true
            self.releaseReclaimHold()
        }
    }

    private func setAlternate(_ on: Bool) {
        guard isAlternateScreen != on else { return }
        isAlternateScreen = on
        show(.alternateScreen(on))
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
        guard attached, replacing == nil, !draining, let client, !outbox.isEmpty else { return }
        draining = true
        let next = outbox.removeFirst()
        if case .size = next { drainingSize = true } else { drainingSize = false }
        let generation = claimGeneration
        let surface = surface
        Task { [weak self] in
            guard let self else { return }
            do {
                let cmd: String
                let reply: Data
                switch next {
                case .size(let columns, let rows):
                    // A release sent at once before this claim reaches the Mac first.
                    await releaseWritten?.value
                    // Hidden since it was queued (shown and hidden again in
                    // one turn): never sent, or it would claim a size no
                    // release follows. Hidden and shown again: the show
                    // queued the current size, so this one is stale (it
                    // would resize the Mac twice).
                    guard claimsSize, generation == claimGeneration else {
                        draining = false
                        drain()
                        return
                    }
                    cmd = "resize-surface"
                    log.notice("surface \(surface, privacy: .public): resize-surface sent \(columns, privacy: .public)x\(rows, privacy: .public) cause=\(self.everAttached && self.attachRetries == 0 ? "requested" : "attach", privacy: .public)")
                    sizeClaimed = true
                    startLeaseRefresh()
                    lastClaimAt = .now
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
                lastError = Self.diagnostic(error)
                if self.client === client {
                    self.client = nil
                    attached = false
                    stopLiveness()
                    handler?(.connection(connectionState))
                    scheduleAutoReattach("a size request failed on the attach channel")
                }
                outbox.insert(next, at: 0)
                draining = false
                return
            }
            draining = false
            drain()
        }
    }

    // MARK: Keystroke round trips

    /// Milliseconds since `typedAt` (the input clock), or nil past the hold limit (keys held over an
    /// outage are an outage, not a slow key).
    private func msSince(_ typedAt: TimeInterval) -> UInt32? {
        let elapsed = now() - typedAt
        guard elapsed >= 0, elapsed <= Self.inputHoldLimit else { return nil }
        return UInt32((elapsed * 1000).rounded())
    }

    /// The Mac answered typed batch `number`: one `ack` sample for the next `link_stat`.
    private func keyAnswered(number: Int, typedAt: TimeInterval) {
        guard let ms = msSince(typedAt) else { return }
        if echoDue?.number == number { echoDueAckMs = ms }
        #if canImport(CmuxMobileLinkFFI)
        recordKeyAck(ackMs: ms)
        #endif
    }

    /// Terminal output came: the echo of the oldest typed batch still waiting for one.
    private func keyEchoed() {
        guard let due = echoDue else { return }
        echoDue = nil
        let ack = echoDueAckMs
        echoDueAckMs = nil
        guard let ms = msSince(due.typedAt) else { return }
        #if canImport(CmuxMobileLinkFFI)
        recordKeyEcho(echoMs: ms, ackMs: ack)
        #endif
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
            let progress = LinkProgress()
            self.laneProgress = progress
            let events = lane.events
            Task { [weak self] in
                for await _ in events { progress.progressed() }
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
    /// Reply age does not stop the pipeline: a high-latency link or one lost
    /// reply must not turn typing into stop-and-wait. The bounded in-flight
    /// window and each request's deadline bound a channel that truly stalls.
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
        guard attached, replacing == nil, !inputWriting else { return }
        expireInput()
        guard !input.isEmpty, let target = inputClient ?? client else { return }
        if input[0].key != nil, !sendKeys {
            // A batch that may have arrived, held for a resend, and the Mac no
            // longer takes keys (its app rolled back): sent again it could
            // run twice. Dropped with the keys after it, the screen told.
            let bytes = input.reduce(0) { $0 + ($1.typed ? $1.bytes.count : 0) }
            let pastes = input.compactMap(\.paste)
            input.removeAll()
            log.notice("surface \(self.surface, privacy: .public): \(bytes, privacy: .public) typed bytes not sent again (the Mac no longer takes send keys)")
            handler?(.inputNotSent(bytes: bytes))
            pastes.forEach(pasteWasNotSent)
            return
        }
        if inputInFlight > 0, inputRecovering || inputTarget !== target || inputInFlight >= Self.maxInputInFlight { return }
        // A composer Send goes as the outbox's request (its key made at the tap), pipelined in
        // tap order up to the outbox's window; past it, the next waits for an answer.
        let composerRequest: String?
        #if canImport(CmuxMobileLinkFFI)
        if let paste = input[0].paste {
            guard let request = composerOutbox.nextRequest() else { return }
            guard Int(request.seq) == paste else {
                // Never by construction (both are in tap order): released, and nothing goes.
                log.fault("surface \(self.surface, privacy: .public): composer send \(request.seq, privacy: .public) is not the queued \(paste, privacy: .public)")
                composerOutbox.linkLost()
                return
            }
            composerRequest = request.paramsJson
        } else {
            composerRequest = nil
        }
        #else
        composerRequest = nil
        #endif
        inputWriting = true
        inputInFlight += 1
        inputTarget = target
        let number = nextInputBatch
        nextInputBatch += 1
        // A resend goes alone under its first key (other bytes under that key
        // would be dropped with it), and a composer paste goes alone as its
        // own request; new keys go together, up to the next resend or paste,
        // in order on the same channel.
        let resendKey = input[0].key
        let paste = input[0].paste
        let count = resendKey != nil || paste != nil ? 1 : (input.firstIndex { $0.key != nil || $0.paste != nil } ?? input.count)
        let taken = input.prefix(count)
        input.removeFirst(count)
        let typedAt = taken[taken.startIndex].at
        let batch = taken.reduce(into: Data()) { $0.append($1.bytes) }
        // The person's own bytes in it: a failed batch of terminal replies
        // alone is no "keys not sent".
        let typedBytes = taken.reduce(0) { $0 + ($1.typed ? $1.bytes.count : 0) }
        let key = composerRequest.flatMap(Self.requestKey) ?? resendKey ?? (sendKeys ? UUID().uuidString : nil)
        let resent = resendKey != nil
        let typedSend = paste.map { typedSends.contains($0) } ?? false
        // Typed keys (no paste, no resend, no terminal replies): this batch's echo is timed.
        let timesEcho = typedBytes > 0 && paste == nil && !resent
        if timesEcho, echoDue == nil {
            echoDue = (number, typedAt)
            echoDueAckMs = nil
        }
        let surface = surface
        let onLane = target !== client
        let laneProgress = laneProgress
        let deadline = inputRequestDeadline
        Task { [weak self] in
            guard let self else { return }
            var written = false
            let started = ContinuousClock.now
            do {
                let submit: @Sendable () async throws -> String = {
                    var params: [String: Any]
                    if let composerRequest,
                       let request = try? JSONSerialization.jsonObject(with: Data(composerRequest.utf8)) as? [String: Any] {
                        params = request
                    } else {
                        params = paste != nil
                            ? ["text": String(decoding: batch, as: UTF8.self), "paste": !typedSend, "submit": true]
                            : ["bytes": batch.base64EncodedString()]
                        if let key { params["key"] = key }
                    }
                    params["surface"] = surface
                    return try await target.submit("send", params: params, deadline: deadline)
                }
                // A lane request gets written and answered with no more than
                // `inputLaneStall` of silence on the lane, or the lane is given
                // up: a lane that keeps taking writes and answering goes on.
                let id: String
                if onLane {
                    guard let submitted = try await Self.within(Self.inputLaneStall, extend: laneProgress.stallExtension(after: Self.inputLaneStall), submit) else {
                        abandonInputLane(target, number: number, batch: batch, typed: typedBytes, key: key, resent: resent, paste: paste, wasWriting: true)
                        return
                    }
                    id = submitted
                    laneProgress.progressed()  // the lane took a write
                } else {
                    id = try await submit()
                }
                written = true
                inputWriting = false
                if inputUnansweredSince == nil { inputUnansweredSince = .now }
                inputProgress += 1
                armTailProbe()
                drainInput()
                let reply: Data
                if onLane {
                    guard let answer = try await Self.within(Self.inputLaneStall, extend: laneProgress.stallExtension(after: Self.inputLaneStall),
                                                             { try await target.reply(to: id) }) else {
                        abandonInputLane(target, number: number, batch: batch, typed: typedBytes, key: key, resent: resent, paste: paste, wasWriting: false)
                        return
                    }
                    reply = answer
                    laneProgress.progressed()  // the lane answered
                } else {
                    reply = try await target.reply(to: id)
                }
                let took = ContinuousClock.now - started
                if took >= deadline {
                    sendsPastFixedDeadline += 1
                    log.notice("send \(number, privacy: .public) answered after \(took, privacy: .public) while it kept moving: a fixed \(deadline, privacy: .public) cut would have dropped it (\(self.sendsPastFixedDeadline, privacy: .public) so far)")
                }
                if timesEcho, Self.error(in: reply) == nil {
                    keyAnswered(number: number, typedAt: typedAt)
                }
                if let error = Self.error(in: reply) {
                    lastError = error
                    log.error("send failed: \(error, privacy: .public)")
                    #if canImport(CmuxMobileLinkFFI)
                    // Refused with nothing written: the text comes back. Any other error may have
                    // typed it (its key stays applied, so a resend would read as sent): "may have
                    // been sent".
                    if let paste { composerAnswered(paste, Self.knownNotDelivered(reply) ? .refused : .uncertain) }
                    #else
                    // A composer paste the daemon refused: the screen gets its text back.
                    pasteWasNotSent(paste)
                    #endif
                } else if let paste {
                    #if canImport(CmuxMobileLinkFFI)
                    composerAnswered(paste, .applied)
                    #else
                    pasteNotSent[paste] = nil
                    typedSends.remove(paste)
                    #endif
                }
            } catch {
                if onLane, Self.madeNoProgress(error) {
                    // Stalled for `deadline`: the lane is given up, as when it was a wall clock.
                    abandonInputLane(target, number: number, batch: batch, typed: typedBytes, key: key, resent: resent, paste: paste, wasWriting: !written)
                    return
                }
                if !written { inputWriting = false }
                lastError = Self.diagnostic(error)
                inputRecovering = true
                if written || target === abandonedInputLane || Self.inputDeliveryUncertain(error) {
                    inputFailed.append((number, batch, typedAt, written: true, typed: typedBytes, key: key, resent: resent, paste: paste))
                } else {
                    // Never written: safe to send again (on the attach channel
                    // when the lane failed, or after the reattach).
                    inputFailed.append((number, batch, typedAt, written: false, typed: typedBytes, key: key, resent: resent, paste: paste))
                }
                if inputClient === target {
                    dropInputLane()
                } else if self.client === target {
                    self.client = nil
                    inputClient = nil
                    attached = false
                    stopLiveness()
                    // Fails this channel's other unanswered sends, which
                    // otherwise wait on a channel nobody reads.
                    Task { await target.close() }
                    handler?(.connection(connectionState))
                    // The keys it held are never sent again (above); the
                    // terminal comes back by itself, not at the next link.
                    scheduleAutoReattach("a send failed on the attach channel")
                }
            }
            inputSettled()
        }
    }

    /// A write deadline/cancellation can race a partial or completed write.
    /// Treat it like a lost reply: the Mac may have applied the keystrokes.
    static func inputDeliveryUncertain(_ error: any Error) -> Bool {
        error is CancellationError || (error as? LinkError)?.code == "write_timeout"
    }

    /// A send's client gave it up after ``inputRequestDeadline`` without progress.
    static func madeNoProgress(_ error: any Error) -> Bool {
        let code = (error as? LinkError)?.code
        return code == DaemonClient.replyTimeout || code == "write_timeout"
    }

    /// The input lane gave no answer in time (`wasWriting`: the batch's
    /// write itself hung): given up, and the batch is not sent again (the
    /// Mac may already have typed it) unless it has a `send` key.
    private func abandonInputLane(_ lane: DaemonClient, number: Int, batch: Data, typed: Int, key: String?, resent: Bool, paste: Int?, wasWriting: Bool) {
        log.error("send on the input lane got no answer; using the attach channel")
        abandonedInputLane = lane
        inputRecovering = true
        inputFailed.append((number, batch, now(), written: true, typed: typed, key: key, resent: resent, paste: paste))
        if wasWriting { inputWriting = false }
        if inputClient === lane { dropInputLane() }
        inputSettled()
    }

    /// A `send` was answered, failed or given up: the next batch may go.
    /// Once a failed channel's sends have all settled, its failed batches go
    /// back before newer keys, in order, unless one of them may have been
    /// typed already: then all of them are dropped and the screen is told,
    /// or, when the Mac takes `send` keys, that one goes again once under
    /// its key (the Mac types it at most once).
    private func inputSettled() {
        inputInFlight -= 1
        inputProgress += 1
        inputUnansweredSince = inputInFlight == 0 ? nil : .now
        guard inputInFlight == 0 else {
            armTailProbe()
            return drainInput()
        }
        tailProbe?.cancel()
        tailProbe = nil
        inputTarget = nil
        abandonedInputLane = nil
        if inputRecovering {
            inputRecovering = false
            let failed = inputFailed.sorted { $0.number < $1.number }
            inputFailed.removeAll()
            #if canImport(CmuxMobileLinkFFI)
            // The composer Send that was out has no answer coming: it goes again under its key.
            composerOutbox.linkLost()
            let outboxResends = true
            #else
            let outboxResends = false
            #endif
            // A written batch of terminal replies alone is no part of a
            // command: losing it costs the keys typed after it nothing. A
            // composer Send is the outbox's to send again (under its key, as
            // often as the link needs): it never makes the keys around it uncertain.
            let uncertain = failed.filter { $0.written && $0.typed > 0 && !(outboxResends && $0.paste != nil) }
            // Back in the queue, in order: a batch that may have arrived (or
            // was a resend) keeps its key and goes alone; one never written
            // goes with the keys after it under a new key.
            let back = failed.filter { $0.typed > 0 }.map {
                (bytes: $0.bytes, at: $0.at, detached: true, typed: true, key: $0.written || $0.resent ? $0.key : nil, paste: $0.paste)
            }
            if !uncertain.isEmpty, sendKeys, uncertain.allSatisfy({ $0.key != nil && !$0.resent }) {
                // Sent again once, from when it was typed: the hold still
                // drops it if the terminal stays away (``expireInput()``).
                log.notice("surface \(self.surface, privacy: .public): \(uncertain.count, privacy: .public) batch(es) that may have arrived go again once under their send keys")
                input.insert(contentsOf: back, at: 0)
                markInputDetached()
            } else if !uncertain.isEmpty {
                // The keys typed since go too: no part of a command may run
                // after an earlier part that may be lost.
                let bytes = failed.reduce(0) { $0 + $1.typed } + input.reduce(0) { $0 + ($1.typed ? $1.bytes.count : 0) }
                let pastes = failed.compactMap(\.paste) + input.compactMap(\.paste)
                input.removeAll()
                log.notice("surface \(self.surface, privacy: .public): \(bytes, privacy: .public) typed bytes not sent again (the Mac may have typed them before the channel failed)")
                handler?(.inputNotSent(bytes: bytes))
                pastes.forEach(pasteWasNotSent)
            } else if !failed.isEmpty {
                // A batch of replies alone is stale after the outage (and a
                // written one may have arrived): dropped.
                input.insert(contentsOf: back, at: 0)
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
                    // Disarming a probe is ordinary progress, not a failed write:
                    // cancellation must not close a healthy channel while its ping
                    // write is still awaiting the link.
                    guard let id = try? await target.submit("ping", closeChannelOnCancel: false) else { break }
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

    /// Silence on the input lane a lane write or answer may take before the lane is given up.
    static let inputLaneStall: Duration = .seconds(10)

    /// `operation`'s result, or nil when it takes longer than `limit` and then `extend` (asked
    /// each time it passes: a progress verdict, `LinkProgress.stallExtension(after:)`) says
    /// stop. Does not wait for `operation` to notice cancellation (a request on a dead channel
    /// never does).
    private static func within<T: Sendable>(_ limit: Duration, extend: (@Sendable () -> Duration?)? = nil,
                                            _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
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
                while !Task.isCancelled, let left = extend?(), left > .zero {
                    try? await Task.sleep(for: left)
                }
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
    /// The Mac confirmed the attach and its replay (`vt-state`, which names
    /// the rows it left out) is not applied yet. No history fetch starts
    /// until it is: one started earlier asked again for the window just sent
    /// (``historyRowsOmitted`` was still the last attach's) and its attach
    /// dropped that replay on the way (a new attach closes the old event
    /// inbox). The load bench's 100,000-row scroll to line 1 took 491
    /// fetches at a 40 ms round trip for about 64 windows.
    private var awaitingReplay = false
    /// Failed reattach attempts since the last good attach.
    private var attachRetries = 0
    /// The reattach retries ran out; the next keystroke, or ``gaveUpRetryDelay``, starts again.
    private var gaveUp = false
    /// Delays before retrying a failed reattach (seconds); then the error shows.
    static let defaultReattachBackoff: [Double] = [0.25, 0.5, 1, 2, 4, 8]
    var reattachBackoff = DaemonTerminalSession.defaultReattachBackoff
    /// After the retries ran out, a fresh round starts on its own this long later (as well as on
    /// a keystroke, Retry or a new link), so a terminal never waits for the person to ask
    /// (Leo, 2026-11-22: "vacuous decisions like that should be just done").
    /// It was 30 s: a terminal whose round failed under a live link then sat dark that long, the
    /// size of "intermittent 30s lag/disconnects on ios app on terminal" (Leo, 2026-11-21). Now
    /// it is the backoff's own last step, so a terminal keeps retrying at the pace it already had.
    var gaveUpRetryDelay: Duration = DaemonTerminalSession.defaultGaveUpRetryDelay
    /// The backoff's longest step (8 s).
    static let defaultGaveUpRetryDelay: Duration =
        .milliseconds(Int64((defaultReattachBackoff.last ?? 8) * 1000))
    private var gaveUpRetry: Task<Void, Never>?

    private func scheduleGaveUpRetry() {
        gaveUpRetry?.cancel()
        let delay = gaveUpRetryDelay
        gaveUpRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.gaveUpRetry = nil
            // A Mac that is gone reattaches every session when its link comes back.
            guard self.gaveUp, !self.macOffline else { return }
            self.reconnect()
        }
    }

    /// An attach that failed for want of a link (`no-link`): it waits for the link's return,
    /// which reattaches it, and spends no retry (so never gives up on it).
    nonisolated static func waitsForTheLink(_ error: any Error) -> Bool {
        (error as? LinkError)?.code == "no-link"
    }

    // MARK: Self-recovery

    /// Leo, 2026-11-21: "i noticed intermittent 30s lag/disconnects on ios app
    /// on terminal." A channel that ended (or went silent) while the link
    /// stayed up waited for the whole link to die (20-35 s) or for ever.
    /// Now the session attaches again by itself, through the reattach backoff.
    private var autoReattach: Task<Void, Never>?
    /// The running reattach was started by ``scheduleAutoReattach(_:)``: a
    /// failure because there is no link stops it quietly (the new link
    /// reattaches every session), never into "Can't reach this terminal".
    private var autoReattaching = false
    /// Asks the link to prove itself now (its quick probe), so a link that
    /// really died is redialed at once instead of after its heartbeat.
    public var onLinkSuspect: (@MainActor () -> Void)?

    /// The liveness check of the attach channel while it is on screen: a
    /// `send` unanswered for ``livenessSendWait`` or no frame at all for
    /// ``livenessQuietWait`` sends a `ping`; no frame within
    /// ``livenessPingTimeout`` after it closes the channel and reattaches.
    /// The link's heartbeat only proves the Mac-to-phone direction (any frame
    /// skips its probe), so a broken uplink under streaming output stalled
    /// keys for 10-35 s.
    private var liveness: Task<Void, Never>?
    var livenessSendWait: Duration = .seconds(2)
    var livenessQuietWait: Duration = .seconds(3)
    var livenessPingTimeout: Duration = .seconds(2)
    static let livenessTick: Duration = .milliseconds(250)
    /// The oldest `send` written and not answered since (the last answer
    /// moves it), nil with none in flight.
    private var inputUnansweredSince: ContinuousClock.Instant?
    /// The liveness check is running (tests).
    var livenessArmed: Bool { liveness != nil }

    /// The channel died under an attached session (it ended, a write failed,
    /// or it went silent): attach again after the backoff's first delay,
    /// without waiting for a new link. A no-op once stopped or ended, while
    /// attached or attaching, and while the Mac is offline (its link
    /// reattaches every session when it comes back).
    private func scheduleAutoReattach(_ why: String) {
        guard handler != nil, !ended, !attached, !attaching, autoReattach == nil else { return }
        let delay = reattachBackoff.first ?? 0.25
        log.notice("surface \(self.surface, privacy: .public): \(why, privacy: .public); reattaching in \(delay, privacy: .public) s")
        onLinkSuspect?()
        autoReattach = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.autoReattach = nil
            guard !self.macOffline, !self.gaveUp else { return }
            self.autoReattaching = true
            self.reconnect()
        }
    }

    /// Starts (or restarts, for a new channel) the liveness check: only
    /// attached and on screen (``setClaimsSize(_:)``); it stops by itself
    /// when the channel changes, is hidden or the session stops.
    private func armLiveness() {
        liveness?.cancel()
        liveness = nil
        guard attached, claimsSize, handler != nil, let client else { return }
        let tick = Self.livenessTick
        liveness = Task { [weak self] in
            var position: UInt64 = 0
            // The last proof the channel is alive: a frame from the Mac, or an answered ping.
            var provenAt = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: tick) } catch { return }
                let seen = await client.receivedPosition
                guard let self, !Task.isCancelled, self.attached, self.claimsSize, self.client === client else { return }
                let at = ContinuousClock.now
                // The screen is behind and holds the Mac back: silence is ours, not the link's.
                if self.outputPaused { provenAt = at; position = seen; continue }
                if seen != position {
                    position = seen
                    // Output proves the Mac-to-phone direction only: a key still
                    // unanswered keeps its own clock (a broken uplink under a
                    // streaming terminal).
                    if self.inputUnansweredSince == nil { provenAt = at }
                }
                let stalled = self.inputUnansweredSince.map { at - max($0, provenAt) >= self.livenessSendWait } ?? false
                let quiet = self.inputUnansweredSince == nil && at - provenAt >= self.livenessQuietWait
                guard stalled || quiet else { continue }
                let timeout = self.livenessPingTimeout
                let answered = (try? await Self.within(timeout) {
                    try await client.request("ping", deadline: timeout)
                }) != nil
                guard !Task.isCancelled, self.client === client else { return }
                if answered {
                    provenAt = .now
                    position = await client.receivedPosition
                    continue
                }
                log.error("surface \(self.surface, privacy: .public): attach channel silent (\(stalled ? "send unanswered" : "no frame", privacy: .public), ping unanswered for \(timeout, privacy: .public)); reattaching")
                self.liveness = nil
                self.channelEnded(client)
                Task { await client.close() }
                return
            }
        }
    }

    private func stopLiveness() {
        liveness?.cancel()
        liveness = nil
    }

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
    /// The 8 s lease, refreshed every 2 s: a phone that went away without a
    /// release gives the Mac its grid back within 8 s, not 45 s.
    static let shortSizeLeaseCapability = "size-lease-v2"
    /// Shared sizing: `size-state` on the attach stream, `note-size-activity`.
    static let sharedSizingCapability = "shared-sizing-v1"
    /// `host-grid-view-v1`: this phone renders a Mac grid larger than its
    /// own (pans, letterboxes), so the daemon need not cap the PTY at it.
    static let hostGridViewCapability = "host-grid-view-v1"
    /// `replay_history_rows` on `attach-surface`: the replay holds the screen
    /// and only that many history rows (latest screen first).
    static let replayHistoryRowsCapability = "attach-replay-history-rows-v1"
    /// `replay_history_start` on `attach-surface`, and windowed `resized`
    /// replays for a viewer that declares it (cmux-tui `commands.md`).
    static let replayHistoryWindowCapability = "attach-replay-history-window-v1"
    /// `send` takes `key`: a repeat of an applied key writes nothing.
    static let sendKeyCapability = "send-key-v1"
    /// `send` takes `submit` (with `paste`): Return in the same request as the paste.
    static let pasteSubmitCapability = "send-expect-agent-v1"
    /// `send` with `submit` and typed text waits past a paste-burst window before Return.
    static let typedSubmitCapability = "send-typed-submit-v1"
    /// `offset` and `generation` on the byte stream's events, and `resume_offset` /
    /// `resume_generation` on `attach-surface`: a reattach gets only the missed bytes
    /// (cmux-tui `terminal-resume-v1`).
    static let terminalResumeCapability = "terminal-resume-v1"
    /// `resume_max_bytes` on `attach-surface`: past it the daemon replays instead.
    static let terminalResumeBoundedCapability = "terminal-resume-bounded-v1"
    /// The smallest bound a resume asks for: a replay is rarely smaller.
    static let minResumeBytes = 64 << 10
    /// What the attach channel lists in `set-client-info`.
    static let clientCapabilities = [shortSizeLeaseCapability, sizeLeaseCapability, sharedSizingCapability, hostGridViewCapability, replayHistoryWindowCapability,
                                     terminalResumeCapability, terminalResumeBoundedCapability]

    /// The Mac's daemon sends an agent CLI's terminal (Claude Code, Codex, opencode) as the
    /// cells that changed instead of its PTY bytes (`agent-cli-frame` events).
    nonisolated static let agentCLIHybridCapability = "agent-cli-hybrid-v1"
    /// The same frames packed (`agent-cli-lean`): a Mac that knows it sends those instead.
    nonisolated static let agentCLIHybridLeanCapability = "agent-cli-hybrid-v2"
    /// Settings → Transport → Agent CLI Screen Changes (off by default), the
    /// `CmuxMobilePreferences.Key.agentCLIHybrid` key; read at each attach.
    nonisolated static let agentCLIHybridDefaultsKey = "cmuxMobile.settings.agentCLIHybrid"

    nonisolated static func agentCLIHybridEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: agentCLIHybridDefaultsKey)
    }

    /// A plain shell's terminal as the same lean frames (its lines and cursor), PTY bytes only
    /// while it runs a full-screen program (cmux-tui `terminal-shell-lines-v1`).
    nonisolated static let shellLinesCapability = "terminal-shell-lines-v1"
    /// `output` at most once per display frame for a terminal that stays on PTY bytes (cmux-tui
    /// `attach-output-coalesce-v1`, #43373): fewer events, the first bytes after idle at once.
    nonisolated static let outputCoalesceCapability = "attach-output-coalesce-v1"

    /// What `set-client-info` declares: the lean stream (agent CLIs, shells, full-screen
    /// programs, coalesced PTY bytes for everything else) only with the setting on.
    static func capabilities(agentCLIHybrid: Bool) -> [String] {
        agentCLIHybrid ? clientCapabilities + leanStreamCapabilities : clientCapabilities
    }

    /// The lean stream's names: cmux-mobile-link `names::TERMINAL_LEAN_STREAM` on the phone
    /// (with `terminal-full-screen-frames-v1`), today's four where the link library is absent.
    #if canImport(CmuxMobileLinkFFI)
    nonisolated static let leanStreamCapabilities = terminalLeanStreamCapabilities()
    #else
    nonisolated static let leanStreamCapabilities = [agentCLIHybridCapability, agentCLIHybridLeanCapability, shellLinesCapability, outputCoalesceCapability]
    #endif

    /// While the size is claimed and the daemon leases it: the same size
    /// again every `sizeLeaseRefresh` (a same-size `resize-surface` renews
    /// the lease and never resizes the terminal). One refresher at a time.
    private func startLeaseRefresh() {
        guard leased, claimsSize, leaseTask == nil else { return }
        let interval = shortLease ? shortLeaseRefresh : sizeLeaseRefresh
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

    /// Sent at once, not behind the outbox: a request there waits for the
    /// answer to the one before it, and on a slow link that wait could
    /// outlast the 8 s lease while the phone is on screen. A size already
    /// queued renews it when it goes out.
    private func refreshLease() {
        guard attached, replacing == nil, claimsSize, sizeClaimed, let client, let size = lastSize else { return }
        guard !outbox.contains(where: { if case .size = $0 { true } else { false } }) else { return }
        let surface = surface
        Task { _ = try? await client.request("resize-surface", params: ["surface": surface, "cols": size.columns, "rows": size.rows]) }
    }

    nonisolated static func lists(_ capability: String, _ identify: Data) -> Bool {
        capabilities(identify).contains(capability)
    }

    /// The `identify` reply's capabilities (none when it has no list).
    nonisolated static func capabilities(_ identify: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: identify) as? [String: Any],
              let data = object["data"] as? [String: Any],
              let capabilities = data["capabilities"] as? [String] else { return [] }
        return capabilities
    }

    /// Whether the daemon takes the viewer's size in `attach-surface`.
    nonisolated static func acceptsInitialSize(_ identify: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: identify) as? [String: Any],
              let data = object["data"] as? [String: Any],
              let capabilities = data["capabilities"] as? [String] else { return false }
        return capabilities.contains("attach-initial-size")
    }

    /// The daemon says the request's error wrote nothing (`error_delivery`).
    nonisolated static func knownNotDelivered(_ reply: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return false }
        return object["error_delivery"] as? String == "known-not-delivered"
    }

    /// A composer request's `key`.
    nonisolated static func requestKey(_ request: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])?["key"] as? String
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
