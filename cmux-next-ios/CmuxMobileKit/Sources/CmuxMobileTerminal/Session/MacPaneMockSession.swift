// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import Foundation

/// A Mac terminal pane as the phone's sizing sees it, for the projection
/// harness (`TerminalProjectionResizeHarnessTests`, the terminal demo's
/// `projection` phase): a shell at the Mac pane's own grid (120x40) under
/// the Mac's default policy, "Fit the smallest viewer". While this phone
/// claims a grid smaller than the pane's, the PTY takes the phone's grid;
/// otherwise the pane's. Each PTY grid change is one SIGWINCH for the program
/// and one reset and replay for the phone (`resized`), as the daemon does.
///
/// It counts what reached the Mac: ``ptyResizes`` (grid changes of the PTY)
/// and ``claimChanges`` (claims and releases the phone sent).
@MainActor
public final class MacPaneMockSession: TerminalSession {
    public let paneGrid: (columns: Int, rows: Int)
    /// The PTY's grid now.
    public private(set) var ptyGrid: (columns: Int, rows: Int)
    /// PTY resizes since the pane opened (SIGWINCHes the program got).
    public private(set) var ptyResizes = 0
    /// Claims and releases the phone sent.
    public private(set) var claimChanges = 0
    /// Each PTY resize, in order ("54x38").
    public private(set) var resizeLog: [String] = []
    public private(set) var programName = "zsh"
    public private(set) var isAlternateScreen = false

    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
    private var claims = true
    private var asked: (columns: Int, rows: Int)?
    private var line = ""
    private var transcript: [String]

    public init(columns: Int = 120, rows: Int = 40) {
        paneGrid = (columns, rows)
        ptyGrid = paneGrid
        transcript = Self.session
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
        handler(.output(replay()))
    }

    public func send(_ bytes: Data) {
        for byte in bytes {
            switch byte {
            case 0x0D:
                transcript.append(Self.prompt + line)
                let command = line
                line = ""
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

    public func stop() { handler = nil }

    /// "Fit the smallest viewer": the claiming phone's grid where it is smaller.
    private var wantedGrid: (columns: Int, rows: Int) {
        guard claims, let asked else { return paneGrid }
        return (min(asked.columns, paneGrid.columns), min(asked.rows, paneGrid.rows))
    }

    private func apply() {
        let grid = wantedGrid
        guard grid != ptyGrid else { return }
        resizePTY(to: grid)
        // `resized`: the Mac's grid, then a reset and the replay at it.
        handler?(.hostGrid(columns: grid.columns, rows: grid.rows))
        handler?(.output(TerminalReclaimHold.reset))
        handler?(.output(replay()))
    }

    private func resizePTY(to grid: (columns: Int, rows: Int)) {
        ptyGrid = grid
        ptyResizes += 1
        resizeLog.append("\(grid.columns)x\(grid.rows)")
    }

    /// The pane's history and prompt, as the Mac's replay draws them: long
    /// lines soft-wrap at the PTY's columns.
    private func replay() -> Data {
        var out = ""
        for line in transcript { out += line + "\r\n" }
        out += Self.prompt + line
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
