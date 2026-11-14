// DEBUG and Demo builds only: never compiled into Production.
#if DEBUG
import Foundation

/// DEBUG: a Mac grid that is not the phone's, without a Mac
/// (`-CmuxMobileTerminalDemo -CmuxMobileHostGridDemo 120x40` for a shell
/// wider than the phone, `... 50x20,tui` for a full-screen app with fewer
/// rows, `... 30x12,top` for procps `top` on the primary screen, started at
/// a prompt the shell marks (OSC 133), then refreshed). The screen must render the grid exactly: pan sideways, letterbox
/// below with the note `30×12 · set by Rig Mac` (PROTOCOL.md "Terminal
/// sizing policy"). The shell has history above its screen, so a grid
/// pinned to the top is told apart from one resting on the composer.
@MainActor
public final class TerminalHostGridDemoSession: TerminalSession {
    public let programName: String
    public private(set) var isAlternateScreen: Bool
    /// `top` on the primary screen instead of a shell.
    private let runsTop: Bool
    public let remoteColumns: Int?
    public let remoteRows: Int?
    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?

    /// `spec`: `<cols>x<rows>` with an optional `,tui`.
    public init?(spec: String) {
        let parts = spec.split(separator: ",")
        let size = parts.first?.split(separator: "x").compactMap { Int($0) } ?? []
        guard size.count == 2, size[0] > 1, size[1] > 1 else { return nil }
        remoteColumns = size[0]
        remoteRows = size[1]
        isAlternateScreen = parts.dropFirst().contains("tui")
        runsTop = !isAlternateScreen && parts.dropFirst().contains("top")
        programName = isAlternateScreen ? "htop" : runsTop ? "top" : "zsh"
    }

    /// The device the demo's grid is set by.
    static let owner = "Rig Mac"

    public static var requestedSpec: String? {
        UserDefaults.standard.string(forKey: "CmuxMobileHostGridDemo")
    }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        self.handler = handler
        handler(.connection(.attached))
        let columns = remoteColumns ?? 80, rows = remoteRows ?? 24
        handler(.hostGrid(columns: columns, rows: rows))
        handler(.hostGridOwner(Self.owner))
        var text = "\u{1B}c"
        if runsTop {
            text += Self.topSession(columns: columns, rows: rows)
        } else if isAlternateScreen {
            handler(.alternateScreen(true))
            text += "\u{1B}[?1049h\u{1B}[H\u{1B}[2J"
            let horizontal = String(repeating: "─", count: columns - 2)
            text += "\u{1B}[1;1H┌\(horizontal)┐"
            for row in 2..<rows { text += "\u{1B}[\(row);1H│\u{1B}[\(row);\(columns)H│" }
            text += "\u{1B}[\(rows);1H└\(horizontal)┘"
            let label = "Mac grid \(columns)×\(rows)"
            text += "\u{1B}[\(rows / 2);\(max(2, (columns - label.count) / 2))H\(label)"
            text += "\u{1B}[\(rows / 2 + 1);3H"
        } else {
            let ruler = (0..<columns).map { String($0 % 10) }.joined()
            let tens = (0..<columns).map { $0 % 10 == 0 ? String(($0 / 10) % 10) : " " }.joined()
            for line in 1...40 { text += "history \(line)\r\n" }
            text += tens + "\r\n" + ruler + "\r\n"
            for line in 1...max(1, rows - 4) {
                let body = "line \(line): " + String(repeating: "=", count: max(0, columns - 20)) + "| end"
                text += String(body.prefix(columns)) + "\r\n"
            }
            text += "$ echo " + String(repeating: "x", count: max(0, columns - 30))
        }
        handler(.output(Data(text.utf8)))
    }

    /// A shell that marks its prompts, `top` typed at one, then procps top's
    /// output: its first paint (`ESC[H ESC[2J`, every row ending in `ESC[K`),
    /// then refreshes that rewrite only the clock row (a row that did not
    /// change is a bare `\r\n`, as top sends it).
    static func topSession(columns: Int, rows: Int) -> String {
        let prompt = "\u{1B}]133;A\u{07}cmux@cmux:~$ \u{1B}]133;B\u{07}"
        let output = "\u{1B}]133;C\u{07}"
        var text = ""
        for line in 1...20 { text += prompt + "echo \(line)\r\n" + output + "\(line)\r\n" }
        text += prompt + "top\r\n" + output
        func clock(_ second: Int) -> String { "top - 08:06:\(String(format: "%02d", second)) up 5 days,  8:06,  1 user" }
        let header = ["Tasks: 101 total,   1 running, 100 sleeping",
                      "%Cpu(s):  0.0 us,  0.3 sy,  0.0 ni, 99.7 id",
                      "MiB Mem :   3915.0 total,   2100.4 free",
                      "MiB Swap:      0.0 total,      0.0 free",
                      "",
                      "    PID USER      PR  NI    VIRT    RES"]
        let processes = ["  17481 cmux      20   0   10044   4096",
                         "      1 root      20   0  167804  11520",
                         "      2 root      20   0       0      0",
                         "      3 root       0 -20       0      0",
                         "      4 root       0 -20       0      0",
                         "      5 root       0 -20       0      0"]
        var lines = [clock(11)] + header + processes
        lines = Array(lines.prefix(rows)) + Array(repeating: "", count: max(0, rows - lines.count))
        // `ESC[?1h ESC=`, the cursor hidden, home and clear: top's first bytes.
        text += "\u{1B}[?1h\u{1B}=\u{1B}[?25l\u{1B}[H\u{1B}[2J"
        text += lines.map { String($0.prefix(columns)) + "\u{1B}[K" }.joined(separator: "\r\n")
        for second in [14, 17] {
            text += "\u{1B}[H" + String(clock(second).prefix(columns)) + "\u{1B}[K"
            text += String(repeating: "\r\n", count: max(0, rows - 1))
        }
        return text
    }

    public func send(_ bytes: Data) {
        // Echo, so typing moves the cursor and the page follows it.
        handler?(.output(bytes))
    }

    public func resize(columns: Int, rows: Int) {}
    public func stop() { handler = nil }
}
#endif
