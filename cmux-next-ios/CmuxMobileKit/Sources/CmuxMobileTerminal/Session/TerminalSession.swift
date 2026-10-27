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
    /// The Mac's terminal has this grid from here on in the byte stream
    /// (`vt-state`, `resized`): the bytes after it are drawn for it, so the
    /// screen resizes its mirror (columns) and places it (rows) at exactly
    /// this point.
    case hostGrid(columns: Int, rows: Int)
    /// The device that sets the Mac's grid changed (its name, or nil when it
    /// is this phone or unknown), for the letterbox note.
    case hostGridOwner(String?)
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

    /// The placeholder's label ("Connecting to Aziz's Mac Studio…", "Reattaching…").
    public var label: String? {
        switch self {
        case .connecting(let mac):
            guard let mac, !mac.isEmpty else { return "Connecting…" }
            return "Connecting to \(mac)…"
        case .reattaching:
            return "Reattaching…"
        case .offline(let mac):
            guard let mac, !mac.isEmpty else { return "Your Mac is offline" }
            return "\(mac) is offline"
        case .attached:
            return nil
        }
    }

    /// A dropped tab (reattaching, or its Mac offline): a warm surface keeps
    /// its last frame live and readable under no overlay; the title pill says
    /// what is going on.
    public var keepsWarmFrame: Bool {
        switch self {
        case .reattaching, .offline: true
        case .connecting, .attached: false
        }
    }

    /// Whether the placeholder shows a spinner: not for an offline Mac,
    /// which nothing on the phone is waiting on.
    public var showsProgress: Bool {
        if case .offline = self { return false }
        return true
    }

    /// Why the composer's Send did not go (nil: attached, it goes). The text
    /// stays in the composer: a command must never run long after it was
    /// typed (termfix-r13 D5, T-INPUT-17).
    public var composerNotSentNotice: String? {
        func named(_ mac: String?) -> String { mac.flatMap { $0.isEmpty ? nil : $0 } ?? "your Mac" }
        switch self {
        case .attached: return nil
        case .offline(let mac): return "Not sent: \(named(mac)) is offline. Send again when it's back."
        // A first attach usually lands within a few hundred ms: the send
        // goes to the session, which holds it that long and says so if the
        // terminal never came (r13 review: a quick Send on a new tab was refused).
        case .connecting: return nil
        case .reattaching(let mac): return "Not sent: reconnecting to \(named(mac)). Send again when it's back."
        }
    }

    /// Said once keys typed during an outage were dropped (``TerminalSessionEvent/inputNotSent(bytes:)``).
    public static let inputNotSentNotice = "Keys typed while your Mac was unreachable were not sent."
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
}

extension TerminalSession {
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

    public var hostGridOwnerName: String? { nil }
}

/// Follows DEC private modes 47, 1047 and 1049 in a byte stream, across chunk
/// boundaries. Sessions that only see bytes use it to derive `alternateScreen`.
public struct AlternateScreenDetector: Sendable {
    public private(set) var isActive = false
    private var pending: [UInt8] = []

    public init() {}

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
