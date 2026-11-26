// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import Foundation

/// A Mac terminal pane as the phone's sizing sees it, for the projection
/// harness (`TerminalProjectionResizeHarnessTests`, the terminal demo's
/// `projection` and `altproj` phases): a shell at the Mac pane's own grid
/// (120x40) under the Mac's default policy, "Fit the smallest viewer". While
/// this phone claims a grid smaller than the pane's, the PTY takes the
/// phone's grid; otherwise the pane's. Each PTY grid change is one SIGWINCH
/// for the program and one reset and replay for the phone (`resized`), as the
/// daemon does.
///
/// `htop` runs a full-screen app on the alternate screen (its screen redrawn
/// at the PTY's grid on each SIGWINCH, `q` quits). `latency` delays the
/// Mac's answer to a claim (a `resized` and its replay) by a round trip, as a
/// phone on LTE sees it. `keepsSize`: a Mac that keeps its grid (Prefer
/// this Mac): a claim never resizes the PTY and no `resized` comes back.
///
/// It counts what reached the Mac: ``ptyResizes`` (grid changes of the PTY)
/// and ``claimChanges`` (claims and releases the phone sent), and what came
/// back: ``replayBytes`` (bytes of every reset's replay, the attach's too).
@MainActor
public final class MacPaneMockSession: TerminalSession {
    public let paneGrid: (columns: Int, rows: Int)
    /// The Mac keeps its grid whatever the phone claims (Prefer this Mac).
    public let keepsSize: Bool
    /// The PTY's grid now.
    public private(set) var ptyGrid: (columns: Int, rows: Int)
    /// PTY resizes since the pane opened (SIGWINCHes the program got).
    public private(set) var ptyResizes = 0
    /// Claims and releases the phone sent.
    public private(set) var claimChanges = 0
    /// Each PTY resize, in order ("54x38").
    public private(set) var resizeLog: [String] = []
    /// Bytes of the replays the phone got (the attach's and each resize's).
    public private(set) var replayBytes = 0
    /// A resize the Mac made whose `resized` and replay have not reached the phone.
    public private(set) var resizeInFlight = false
    public private(set) var programName = "zsh"
    public private(set) var isAlternateScreen = false

    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
    private var claims = true
    private var asked: (columns: Int, rows: Int)?
    private var line = ""
    private var transcript: [String]
    private let latency: Duration
    /// The answer to the last resize still on its way (a newer one replaces it).
    private var answer: Task<Void, Never>?

    /// `transcript`: the pane's history (lines, oldest first); a short shell
    /// session by default.
    public init(columns: Int = 120, rows: Int = 40, transcript: [String]? = nil, program: String? = nil,
                latency: Duration = .zero, keepsSize: Bool = false) {
        paneGrid = (columns, rows)
        self.keepsSize = keepsSize
        ptyGrid = paneGrid
        self.transcript = transcript ?? Self.session
        self.latency = latency
        if program == "htop" {
            self.transcript.append(Self.prompt + "htop")
            programName = "htop"
            isAlternateScreen = true
        }
    }

    public var remoteRows: Int? { ptyGrid.rows }
    public var remoteColumns: Int? { ptyGrid.columns }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        self.handler = handler
        // The attach carries the phone's grid when it claims one (as
        // `attach-surface {cols, rows}` does): the PTY resizes once, before
        // the replay.
        let grid = wantedGrid
        if grid != ptyGrid { resizePTY(to: grid) }
        handler(.hostGrid(columns: ptyGrid.columns, rows: ptyGrid.rows))
        handler(.output(TerminalReclaimHold.reset))
        let replay = replay()
        replayBytes += replay.count
        handler(.output(replay))
    }

    public func send(_ bytes: Data) {
        if isAlternateScreen {
            // htop: `q` (or F10, Ctrl-C) quits; other keys are its own.
            if bytes.contains(0x71) || bytes.contains(0x03) || bytes == Data("\u{1B}[21~".utf8) { exitHtop() }
            return
        }
        for byte in bytes {
            switch byte {
            case 0x0D:
                transcript.append(Self.prompt + line)
                let command = line
                line = ""
                if command == "htop" {
                    handler?(.output(Data("\r\n".utf8)))
                    enterHtop()
                    continue
                }
                var out = "\r\n"
                if !command.isEmpty {
                    let reply = "\(command): the Mac's shell ran it at \(ptyGrid.columns) columns; this line is long enough to wrap on a phone"
                    transcript.append(reply)
                    out += reply + "\r\n"
                }
                handler?(.output(Data((out + Self.prompt).utf8)))
            case 0x7F:
                guard !line.isEmpty else { continue }
                line.removeLast()
                handler?(.output(Data("\u{8} \u{8}".utf8)))
            case 0x20...0x7E:
                line.append(Character(UnicodeScalar(byte)))
                handler?(.output(Data([byte])))
            default:
                break
            }
        }
    }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        asked = (columns, rows)
        guard handler != nil else { return }
        apply()
    }

    public func setClaimsSize(_ claims: Bool) {
        guard claims != self.claims else { return }
        self.claims = claims
        claimChanges += 1
        guard handler != nil else { return }
        apply()
    }

    public func stop() {
        handler = nil
        answer?.cancel()
    }

    /// "Fit the smallest viewer": the claiming phone's grid where it is
    /// smaller (never, for a Mac that keeps its size).
    private var wantedGrid: (columns: Int, rows: Int) {
        guard claims, !keepsSize, let asked else { return paneGrid }
        return (min(asked.columns, paneGrid.columns), min(asked.rows, paneGrid.rows))
    }

    private func apply() {
        let grid = wantedGrid
        guard grid != ptyGrid else { return }
        resizePTY(to: grid)
        // `resized`: the Mac's grid, then a reset and the replay at it, a
        // round trip after the claim left the phone.
        answer?.cancel()
        guard latency > .zero else { return answerResize() }
        resizeInFlight = true
        answer = Task { @MainActor [weak self, latency] in
            try? await ContinuousClock().sleep(for: latency)
            guard let self, !Task.isCancelled else { return }
            self.answerResize()
        }
    }

    private func answerResize() {
        resizeInFlight = false
        handler?(.hostGrid(columns: ptyGrid.columns, rows: ptyGrid.rows))
        handler?(.output(TerminalReclaimHold.reset))
        let replay = replay()
        replayBytes += replay.count
        handler?(.output(replay))
    }

    private func resizePTY(to grid: (columns: Int, rows: Int)) {
        ptyGrid = grid
        ptyResizes += 1
        resizeLog.append("\(grid.columns)x\(grid.rows)")
    }

    private func enterHtop() {
        programName = "htop"
        isAlternateScreen = true
        handler?(.output(Data(("\u{1B}]2;htop\u{7}\u{1B}[?1049h\u{1B}[?25l" + MockHtop.render(columns: ptyGrid.columns, rows: ptyGrid.rows, tick: 0)).utf8)))
    }

    private func exitHtop() {
        programName = "zsh"
        isAlternateScreen = false
        handler?(.output(Data(("\u{1B}[?25h\u{1B}[?1049l\u{1B}]2;zsh\u{7}" + Self.prompt).utf8)))
    }

    /// The pane's history and prompt, as the Mac's replay draws them: long
    /// lines soft-wrap at the PTY's columns. With htop up, its screen at the
    /// PTY's grid follows on the alternate screen (`vt-state` replays both).
    private func replay() -> Data {
        var out = ""
        for line in transcript { out += line + "\r\n" }
        if isAlternateScreen {
            out += "\u{1B}]2;htop\u{7}\u{1B}[?1049h\u{1B}[?25l" + MockHtop.render(columns: ptyGrid.columns, rows: ptyGrid.rows, tick: 0)
        } else {
            out += Self.prompt + line
        }
        return Data(out.utf8)
    }
    private static let prompt = "\u{1B}[32m~/src/cmux\u{1B}[0m $ "

    private static let session: [String] = {
        var lines = [
            prompt + "git log --oneline -3",
            "\u{1B}[33m06a84d2a35a5\u{1B}[0m cmux-vm: image roll first in production",
            "\u{1B}[33mf6fadfbd8ff4\u{1B}[0m cmux-next-ios: the soft keyboard never resizes the remote terminal (#41895)",
            "\u{1B}[33ma2cd57b64ffa\u{1B}[0m cmux-next-ios: app switch, lock and link blips keep the terminal size claim (#41902)",
            prompt + "claude",
            "\u{1B}[1m⏺\u{1B}[0m The phone keeps its own copy of the terminal at the Mac's width and re-wraps each line at its own width, so the Mac pane never resizes when the phone attaches, rotates, or shows the keyboard.",
            "  \u{1B}[2m⎿  Read crates/cmux-terminal-projection/src/project.rs (412 lines)\u{1B}[0m",
            "\u{1B}[1m⏺\u{1B}[0m Each feed repaints from the first row that changed, so an echo reaches the phone as the key itself.",
        ]
        for i in 1...24 {
            lines.append("  build step \(i): compiling cmux-terminal-projection v0.1.0 (/Users/dev/src/cmux/cmux-tui/crates/cmux-terminal-projection) in \(i * 7) ms")
        }
        return lines
    }()
}
#endif
