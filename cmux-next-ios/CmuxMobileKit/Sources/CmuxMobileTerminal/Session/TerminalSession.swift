import Foundation

/// What a terminal session reports to the screen.
public enum TerminalSessionEvent: Sendable, Equatable {
    /// Bytes the program wrote (the PTY output, or the owner's mirrored stream).
    case output(Data)
    /// The program entered (true) or left (false) the alternate screen. The
    /// screen switches between native scrollback (false) and TUI mode (true).
    case alternateScreen(Bool)
    /// The window title the program set (OSC 0/2), or the program name.
    case title(String)
    /// The session ended.
    case exited(code: Int32)
    /// The session's link to the Mac's terminal changed (see ``TerminalConnectionState``).
    case connection(TerminalConnectionState)
    /// Keys typed while the terminal was unreachable were dropped, not sent
    /// late (a command must never run long after it was typed).
    case inputNotSent(bytes: Int)
    /// Keys the person typed while the terminal was not attached wait for the attach: `bytes`
    /// of them, 0 once none do (they went, were dropped, or were discarded). The screen says
    /// keys are pending and offers to discard them (``TerminalSession/discardHeldInput()``):
    /// they are typed into whatever the terminal shows after the attach.
    case inputHeld(bytes: Int)
    /// The Mac's terminal has this grid from here on in the byte stream
    /// (`vt-state`, `resized`): the bytes after it are drawn for it, so the
    /// screen resizes its mirror (columns) and places it (rows) at exactly
    /// this point.
    case hostGrid(columns: Int, rows: Int)
    /// The device that sets the Mac's grid changed (its name, or nil when it
    /// is this phone or unknown), for the letterbox note.
    case hostGridOwner(String?)
    /// The Mac stamped the redraw whose bytes the session just gave (`pseq`), and its line
    /// arrived at `receivedMs` (epoch ms): the screen reports when it painted it
    /// (``TerminalPaintTally``, `phone-frames` `paint`).
    case paintMark(seq: Int, receivedMs: Double)
}

/// Whether the screen shows the Mac's terminal yet. Anything but `attached`
/// draws the honest placeholder (a skeleton terminal, a spinner and a short
/// label), never made-up output.
public enum TerminalConnectionState: Sendable, Equatable {
    /// No terminal on the Mac yet: the link, the workspace tree or the first
    /// attach is still coming. `mac` names the Mac when it is known.
    case connecting(mac: String?)
    /// Was attached; the link dropped and the session is attaching again.
    case reattaching(mac: String?)
    /// The Mac is offline or out of reach for longer than a blip: the page
    /// keeps its last frame and says so, and attaches again by itself when
    /// the Mac is back.
    case offline(mac: String?)
    /// Attachment failed; diagnostic output is not a successful connection.
    case failed(message: String)
    /// Attached: the screen mirrors the Mac's terminal.
    case attached

    public var isAttached: Bool { self == .attached }

    /// The state after `event`: a `.connection` event sets it, and bytes from
    /// the Mac mean the terminal is attached (even from a session that sends
    /// no `.connection` events).
    public func applying(_ event: TerminalSessionEvent) -> TerminalConnectionState {
        switch event {
        case .connection(let state): state
        case .output: .attached
        default: self
        }
    }

    /// Whether a tab's grid card shows the connecting placeholder (spinner
    /// and label): only once its session was started (its page was laid
    /// out). A tab not opened in this launch has no session yet, so a spinner
    /// there never ends (D5, T-TABS-02): it shows its saved frame, or the
    /// static placeholder.
    public func cardShowsConnecting(sessionStarted: Bool) -> Bool {
        !isAttached && sessionStarted
    }

    /// The quiet line by the composer once an outage has lasted
    /// `QuietStatusGate.threshold` (nil: attached). Plain words, never a
    /// transport error ("daemon channel closed").
    public var quietLine: String? {
        func named(_ mac: String?) -> String { mac.flatMap { $0.isEmpty ? nil : $0 } ?? "your Mac" }
        switch self {
        case .connecting(let mac): return "Connecting to \(named(mac))…"
        case .reattaching(let mac): return "Reconnecting to \(named(mac))…"
        case .offline(let mac): return mac.flatMap { $0.isEmpty ? nil : "\($0) is offline" } ?? "Your Mac is offline"
        case .failed: return "Can't reach this terminal"
        case .attached: return nil
        }
    }

    /// The title pill's subtitle once an outage lasted
    /// `QuietStatusGate.threshold` (nil: attached). A few words in place of
    /// the working directory: the page itself gets no status row. A link still
    /// coming back (connecting, reattaching) says nothing: the pill keeps the
    /// working directory and the last frame stays (Leo, 2026-11-24: "let's just
    /// keep optimistically connecting and reinforcing the connection").
    public var pillSubtitle: String? {
        switch self {
        case .connecting, .reattaching: return nil
        case .offline: return "Mac offline"
        case .failed: return "Can't connect"
        case .attached: return nil
        }
    }

    /// A dropped tab (reattaching, or its Mac offline): a warm surface keeps
    /// its last frame live and readable under no overlay; the title pill says
    /// what is going on.
    public var keepsWarmFrame: Bool {
        switch self {
        case .reattaching, .offline, .failed: true
        case .connecting, .attached: false
        }
    }

    /// Whether the placeholder shows a spinner: not for an offline Mac,
    /// which nothing on the phone is waiting on.
    public var showsProgress: Bool {
        if case .offline = self { return false }
        if case .failed = self { return false }
        return true
    }

    /// Why the composer's Send did not go (nil: it goes). The text stays in
    /// the composer: a command must never run long after it was typed
    /// (termfix-r13 D5, T-INPUT-17). A reattach (a blip) is not refused: the
    /// send waits in the session's bounded hold (`inputHoldLimit`) and goes
    /// once the terminal is back, or comes back to the composer if it never
    /// comes (``TerminalSessionEvent/inputNotSent(bytes:)``).
    public var composerNotSentNotice: String? {
        func named(_ mac: String?) -> String { mac.flatMap { $0.isEmpty ? nil : $0 } ?? "your Mac" }
        switch self {
        case .attached: return nil
        case .offline(let mac): return "Not sent: \(named(mac)) is offline. Send again when it's back."
        case .failed(let message): return message
        // A first attach usually lands within a few hundred ms: the send
        // goes to the session, which holds it that long and says so if the
        // terminal never came (r13 review: a quick Send on a new tab was refused).
        case .connecting: return nil
        case .reattaching: return nil
        }
    }

    /// Said once keys typed during an outage were dropped (``TerminalSessionEvent/inputNotSent(bytes:)``).
    public static let inputNotSentNotice = "Keys typed while your Mac was unreachable were not sent."
    /// Said while keys typed before the attach wait for it (``TerminalSessionEvent/inputHeld(bytes:)``),
    /// beside Discard.
    public static let inputHeldNotice = "Keys you typed go when the terminal reconnects."
    /// Said when the composer's message did not reach the Mac's terminal (its text is back in the composer).
    public static let composerSendNotSentNotice = "Your message was not sent."
    /// Said when the composer's message may have reached the Mac's terminal but its answer never
    /// came (the link failed after it went out): its text stays out of the composer, so a second
    /// Send never types it twice.
    public static let composerSendMaybeSentNotice = "Your message may have been sent. Check the terminal before sending it again."
}

/// One terminal on a Mac, as the phone sees it: bytes in, input out, resize and
/// the alternate screen flag. The link-backed session (`DaemonTerminalSession`,
/// the cmux-mobile-link-ffi `daemon` channel) is the real one; ``PendingTerminalSession``
/// stands in until it exists; the scripted mock exists only in DEBUG builds.
@MainActor
public protocol TerminalSession: AnyObject {
    /// The program running in the foreground, for the composer placeholder ("Send to zsh").
    var programName: String { get }
    /// Whether the program is on the alternate screen now.
    var isAlternateScreen: Bool { get }
    /// Starts delivering events. Called once by the screen; events arrive on the main actor.
    func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void)
    /// Bytes for the PTY (keys encoded by Ghostty, composer text, paste).
    func send(_ bytes: Data)
    /// Bytes that are no key the person typed, pressed or pasted: Ghostty's
    /// replies to terminal queries (cursor and device reports, focus,
    /// visibility and size reports), and the wheel and click reports of a
    /// scroll or a tap. A session that holds keys through an outage drops these
    /// instead, and never reports them as ``TerminalSessionEvent/inputNotSent(bytes:)``.
    func sendReply(_ bytes: Data)
    /// The composer's Send: `text` as one paste and Return, in one request to
    /// where the terminal runs, which brackets the paste by its own live
    /// DEC mode 2004 and writes Return right after it (a Mac daemon's
    /// `send {text, paste:true, submit:true}`). The phone's mirror may have
    /// lost mode 2004 in a replay, and its paste and its Return were two
    /// writes 60 ms apart: a draft could stay unsent in the program's prompt.
    /// Returns false when this session cannot (no Mac daemon, or one without
    /// `send-expect-agent-v1`): the screen then pastes through its mirror.
    /// `notSent` is called once, on the main actor, if the text never reached
    /// the terminal (dropped before it went out, or refused): the screen then
    /// gives it back. `maybeSent` is called instead when it went out and no
    /// answer came in time: it may have been typed, so the text stays out of
    /// the composer (a second Send would type it twice).
    func sendPasteAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void, maybeSent: @escaping @MainActor () -> Void) -> Bool
    /// The composer's Send of a one-line draft to a full-screen program:
    /// `text` typed and Return, in one request to where the terminal runs
    /// (a Mac daemon's `send {text, submit:true}` with `send-typed-submit-v1`),
    /// never the text and a separate Return a link blip can split. Returns
    /// false when this session cannot: the screen then types through its
    /// mirror. `notSent` and `maybeSent` as for
    /// ``sendPasteAndSubmit(_:notSent:maybeSent:)``.
    func sendTypedAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void, maybeSent: @escaping @MainActor () -> Void) -> Bool
    /// The screen's grid in cells: what a TUI should draw (rows between the
    /// toolbar and the composer with the keyboard down).
    func resize(columns: Int, rows: Int)
    /// Stops delivering events.
    func stop()
    /// Rows of the remote screen this session mirrors (nil: a local session).
    var remoteRows: Int? { get }
    /// Columns of the remote screen (the Mac's PTY grid; nil: a local
    /// session, or not known yet). When they are not the phone's own, the
    /// screen renders them exactly and pans (`TerminalHostGridLayout`).
    var remoteColumns: Int? { get }
    /// Whether the session shows the Mac's terminal now. Read once when the
    /// screen is built; changes arrive as ``TerminalSessionEvent/connection(_:)``.
    var connectionState: TerminalConnectionState { get }
    /// The screen has more output waiting than it can take: stop delivering
    /// `.output` until it asks again (`false`). Sessions that cannot hold
    /// the program back ignore it.
    func setOutputPaused(_ paused: Bool)
    /// The terminal is on screen in the foreground app (true) or not:
    /// only then does this phone's size count on the Mac (a session on the
    /// Mac releases its size when told false and claims it again on true).
    /// Driven by ``TerminalSizeClaimer``. Sessions without a Mac ignore it.
    func setClaimsSize(_ claims: Bool)
    /// The person tapped or typed in the terminal: on a Mac terminal this
    /// view becomes the active device for the Mac's sizing policy (sessions
    /// rate-limit it themselves). Sessions without a Mac ignore it.
    func noteInteraction()
    /// The name of the device whose size the Mac's grid has now, when that
    /// is not this phone (the letterbox note). Nil when unknown.
    var hostGridOwnerName: String? { get }
    /// Whether ``clearHistory()`` clears the terminal where it runs (the Mac's daemon owns
    /// a Mac terminal's screen and scrollback). False: the screen sends Ctrl-L instead.
    var clearsHistory: Bool { get }
    /// Clear Screen and Scrollback where the terminal runs, so every view of it clears
    /// (the Mac's Cmd-K, `clear-history`). A full-screen app is left as it is.
    func clearHistory() async throws
    /// The reader scrolled up to the oldest row the screen holds: a session
    /// that attached with the latest screen first brings older rows (a Mac
    /// terminal, `attach-replay-history-rows-v1`). Called as often as the page
    /// scrolls there; the session decides. Others ignore it. Returns whether
    /// it asked (a mirror reset and a longer replay follow).
    @discardableResult
    func loadOlderHistory() -> Bool
    /// The mirror holds a window far above the Mac's screen (a reader went up
    /// a long history, `attach-replay-history-window-v1`): its history rows,
    /// then the Mac's screen, without the rows between. Nil: the mirror's rows
    /// reach the screen. The screen asks for newer rows (``loadNewerHistory(toTheScreen:)``)
    /// when its reader comes down to the window's last row.
    var historyWindowRows: Int? { get }
    /// The reader came down to the last row of the window the mirror holds
    /// (``historyWindowRows``): the window moves down toward the screen; or,
    /// `toTheScreen`, the reader came up from the screen to the window: the
    /// mirror holds the newest rows again.
    /// Called as often as the page scrolls there; the session decides.
    /// Returns whether it asked (a mirror reset and a replay follow).
    @discardableResult
    func loadNewerHistory(toTheScreen: Bool) -> Bool
    /// Before the first attach: the screen will put a reader back on a row
    /// `rows` rows above the end (a tab back from the warm set,
    /// ``TerminalScrollPlace``), so a session that attaches with the latest
    /// screen first asks for at least that much history at once. Others ignore it.
    func requestHistoryRows(_ rows: Int)
    /// The phone projects this terminal itself (``TerminalProjectingSession``):
    /// the session claims a size only when told to, and never holds the
    /// Mac's own grid back from the screen while the primary screen shows.
    /// Sessions without a Mac ignore it.
    func setProjectsLocally(_ projects: Bool)
    /// Where the reader is, in the page's rows: from the document's end to
    /// the top of the screen they read (the screen's height at the bottom).
    /// A projection keeps those lines when it re-wraps at a new width.
    /// Called as the page scrolls; others ignore it.
    func noteReaderRowsFromEnd(_ rows: Int)
    /// A vertical pan over a full-screen app (the alternate screen), `rows`
    /// positive toward older content: the rows of wheel that still go to the
    /// app. A session that holds the rows the app scrolled off paints a pan
    /// within them itself (`cmux-terminal-projection` decides) and returns
    /// 0; others send all of it, as before.
    func panHeldRows(_ rows: Double) -> Double
    /// A key or a tap: a session showing held rows shows the app's live
    /// screen again. Others ignore it.
    func returnToLiveScreen()
    /// The session itself, under any session wrapping it (the projection).
    var underlyingSession: AnyObject { get }
    /// One pan of the screen ended: its frame intervals, for a session with a Mac to log
    /// there (`phone-frames`). Others ignore it.
    func reportScrollFrames(_ pan: TerminalPanFrames)
    /// Stamped redraws the screen painted (`[seq, received, painted]`, epoch ms), for a
    /// session with a Mac to join with its stamps (`phone-frames` `paint`). Others ignore it.
    func reportPaint(_ samples: [TerminalPaintTally.Sample])
    /// Drops the keys held for the attach (``TerminalSessionEvent/inputHeld(bytes:)``), at the
    /// person's word: none is sent. Sessions that hold no keys ignore it.
    func discardHeldInput()
}

extension TerminalSession {
    /// Sessions that never hold keys send a reply as they send keys.
    public func sendReply(_ bytes: Data) { send(bytes) }

    /// Sessions with no Mac daemon paste through the screen's mirror.
    public func sendPasteAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void, maybeSent: @escaping @MainActor () -> Void) -> Bool { false }

    /// Sessions with no Mac daemon type through the screen's mirror.
    public func sendTypedAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void, maybeSent: @escaping @MainActor () -> Void) -> Bool { false }

    /// Rows of the remote screen this session mirrors, when it mirrors one
    /// (a terminal on the Mac). The screen then maps the remote primary
    /// screen onto the bottom of its taller surface (``TerminalRowShift``).
    public var remoteRows: Int? { nil }

    public var remoteColumns: Int? { nil }

    /// Sessions that do not report a connection are always attached.
    public var connectionState: TerminalConnectionState { .attached }

    public func setOutputPaused(_ paused: Bool) {}

    public func setClaimsSize(_ claims: Bool) {}

    public func noteInteraction() {}

    public var clearsHistory: Bool { false }

    public func clearHistory() async throws {}

    @discardableResult
    public func loadOlderHistory() -> Bool { false }

    public var historyWindowRows: Int? { nil }

    @discardableResult
    public func loadNewerHistory(toTheScreen: Bool) -> Bool { false }

    public func requestHistoryRows(_ rows: Int) {}

    public func setProjectsLocally(_ projects: Bool) {}

    public func noteReaderRowsFromEnd(_ rows: Int) {}

    public func panHeldRows(_ rows: Double) -> Double { rows }

    public func returnToLiveScreen() {}

    public var underlyingSession: AnyObject { self }
    public func reportScrollFrames(_ pan: TerminalPanFrames) {}

    public func reportPaint(_ samples: [TerminalPaintTally.Sample]) {}

    public func discardHeldInput() {}

    public var hostGridOwnerName: String? { nil }
}

/// Follows DEC private modes 47, 1047 and 1049 in a byte stream, across chunk
/// boundaries. Sessions that only see bytes use it to derive `alternateScreen`.
/// It also follows the input modes (``inputModeNumbers``), so a terminal that was
/// reset can be put back in the modes the stream set (``restoringBytes``).
public struct AlternateScreenDetector: Sendable {
    /// The DEC private modes that change what the terminal's keys, pastes and touches
    /// send: cursor keys (1), mouse tracking (1000, 1002, 1003), focus events (1004),
    /// mouse encodings (1005, 1006, 1015) and bracketed paste (2004).
    public static let inputModeNumbers: Set<Int> = [1, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 2004]

    public private(set) var isActive = false
    /// The ``inputModeNumbers`` the stream set and has not reset since.
    public private(set) var inputModes: Set<Int> = []
    private var pending: [UInt8] = []

    public init() {}

    /// A stream that is already on the alternate screen (`active`) when it starts.
    public init(active: Bool) {
        isActive = active
    }

    /// The bytes that put a reset terminal back in the modes the stream set: the
    /// alternate screen, then the input modes. Empty when it set none.
    public var restoringBytes: Data {
        var out = isActive ? "\u{1B}[?1049h" : ""
        for mode in inputModes.sorted() { out += "\u{1B}[?\(mode)h" }
        return Data(out.utf8)
    }

    /// Scans `bytes`; returns the new state when it changed in this chunk.
    public mutating func scan(_ bytes: Data) -> Bool? {
        let before = isActive
        var buffer = pending
        buffer.append(contentsOf: bytes)
        pending.removeAll(keepingCapacity: true)
        var index = 0
        while index < buffer.count {
            guard buffer[index] == 0x1B else { index += 1; continue }
            // ESC [ ? digits (; digits)* h|l
            var cursor = index + 1
            guard cursor < buffer.count else { pending = Array(buffer[index...]); break }
            guard buffer[cursor] == 0x5B else { index += 1; continue }
            cursor += 1
            guard cursor < buffer.count else { pending = Array(buffer[index...]); break }
            guard buffer[cursor] == 0x3F else { index += 1; continue }
            cursor += 1
            var params: [Int] = []
            var value = 0
            var hasDigit = false
            var complete = false
            while cursor < buffer.count, cursor - index < 32 {
                let byte = buffer[cursor]
                if byte >= 0x30, byte <= 0x39 {
                    value = value * 10 + Int(byte - 0x30)
                    hasDigit = true
                } else if byte == 0x3B {
                    params.append(value); value = 0; hasDigit = false
                } else {
                    if hasDigit { params.append(value) }
                    if byte == 0x68 || byte == 0x6C {
                        if params.contains(where: { $0 == 47 || $0 == 1047 || $0 == 1049 }) {
                            isActive = byte == 0x68
                        }
                        for mode in params where Self.inputModeNumbers.contains(mode) {
                            if byte == 0x68 { inputModes.insert(mode) } else { inputModes.remove(mode) }
                        }
                    }
                    complete = true
                    break
                }
                cursor += 1
            }
            if !complete, cursor >= buffer.count, cursor - index < 32 {
                pending = Array(buffer[index...])
                break
            }
            index = cursor + 1
        }
        return isActive == before ? nil : isActive
    }
}
