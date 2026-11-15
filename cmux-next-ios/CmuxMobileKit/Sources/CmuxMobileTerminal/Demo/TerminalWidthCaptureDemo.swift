#if os(iOS) && DEBUG
import Foundation

/// DEBUG only: captures for Leo's choice of how the phone shows a Mac terminal
/// narrower or wider than the phone (resize, reflow, or mixed). Launch the
/// terminal demo with `-CmuxMobileTerminalDemoPhases widthcapture`, plus
/// `-CmuxMobileWidthCaptureContent claude|vim|shell` and
/// `-CmuxMobileWidthCaptureColumns N` (the Mac pane's columns).
/// TerminalWidthModesCaptureTests takes a screenshot at each stage the
/// driver names in the `debug.terminal-demo` label:
/// `w.<stage>.pty<cols>x<rows>.rz<PTY resizes>`.
@MainActor
enum TerminalWidthCaptureDemo {
    static var isRequested: Bool {
        UserDefaults.standard.string(forKey: "CmuxMobileTerminalDemoPhases")?
            .split(separator: ",").contains("widthcapture") == true
    }

    static var content: TerminalWidthCapturePane.Content {
        UserDefaults.standard.string(forKey: "CmuxMobileWidthCaptureContent")
            .flatMap(TerminalWidthCapturePane.Content.init(rawValue:)) ?? .claude
    }

    static var columns: Int {
        let n = UserDefaults.standard.integer(forKey: "CmuxMobileWidthCaptureColumns")
        return n > 0 ? n : 120
    }

    /// The pane ``session()`` made last.
    private(set) static weak var pane: TerminalWidthCapturePane?

    /// The pane, through the session the app builds for a Mac terminal.
    static func session() -> any TerminalSession {
        let pane = TerminalWidthCapturePane(content: content, columns: columns, rows: 40)
        self.pane = pane
        return TerminalSessionChoice.session(live: pane, mockDataEnabled: false, macName: "Mac", programName: pane.programName)
    }

    static func run(model: TerminalModel) async {
        let pane = Self.pane
        let clock = ContinuousClock()
        func wait(_ seconds: Double) async { try? await clock.sleep(for: .milliseconds(Int(seconds * 1000))) }
        func note(_ stage: String) {
            let grid = pane.map { "pty\($0.ptyGrid.columns)x\($0.ptyGrid.rows).rz\($0.ptyResizes)" } ?? "pty?"
            let label = "w.\(stage).\(grid)"
            print("[terminal-demo] \(label)")
            model.demoNote = label
        }
        note("start")
        await wait(4)
        note("attached")
        await wait(4)
        model.toggleKeyboard()
        await wait(2.5)
        note("kbshown")
        await wait(4)
        model.toggleKeyboard()
        await wait(2.5)
        note("kbhidden")
        await wait(4)
        note("done")
    }
}

/// A Mac terminal pane at its own grid under "Fit the smallest viewer": while
/// the phone claims a smaller grid, the PTY takes it; otherwise the pane's.
/// Each PTY change redraws the program at the new grid (its SIGWINCH) and
/// reaches the phone as a grid, a reset and a replay, as the daemon sends it.
///
/// The programs draw what the real ones do at a width W:
/// - `claude`: Claude Code inline on the primary screen: a welcome box,
///   answers word-wrapped by the program at W, dividers W wide.
/// - `vim`: a full-screen editor on the alternate screen with a status line.
/// - `shell`: plain shell output whose long lines the terminal soft-wraps.
@MainActor
final class TerminalWidthCapturePane: TerminalSession {
    enum Content: String { case claude, vim, shell }

    let content: Content
    let paneGrid: (columns: Int, rows: Int)
    private(set) var ptyGrid: (columns: Int, rows: Int)
    private(set) var ptyResizes = 0
    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
    private var claims = true
    private var asked: (columns: Int, rows: Int)?

    init(content: Content, columns: Int, rows: Int) {
        self.content = content
        paneGrid = (columns, rows)
        ptyGrid = paneGrid
    }

    var programName: String {
        switch content {
        case .claude: "claude"
        case .vim: "vim"
        case .shell: "zsh"
        }
    }

    var isAlternateScreen: Bool { content == .vim }
    var remoteRows: Int? { ptyGrid.rows }
    var remoteColumns: Int? { ptyGrid.columns }

    func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        self.handler = handler
        let grid = wantedGrid
        if grid != ptyGrid { resizePTY(to: grid) }
        emitScreen()
    }

    func send(_ bytes: Data) {}

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        asked = (columns, rows)
        guard handler != nil else { return }
        apply()
    }

    func setClaimsSize(_ claims: Bool) {
        guard claims != self.claims else { return }
        self.claims = claims
        guard handler != nil else { return }
        apply()
    }

    func stop() { handler = nil }

    private var wantedGrid: (columns: Int, rows: Int) {
        guard claims, let asked else { return paneGrid }
        return (min(asked.columns, paneGrid.columns), min(asked.rows, paneGrid.rows))
    }

    private func apply() {
        let grid = wantedGrid
        guard grid != ptyGrid else { return }
        resizePTY(to: grid)
        emitScreen()
    }

    private func resizePTY(to grid: (columns: Int, rows: Int)) {
        ptyGrid = grid
        ptyResizes += 1
    }

    private func emitScreen() {
        handler?(.hostGrid(columns: ptyGrid.columns, rows: ptyGrid.rows))
        if content == .vim { handler?(.alternateScreen(true)) }
        handler?(.output(Self.reset))
        handler?(.output(Data(draw(columns: ptyGrid.columns, rows: ptyGrid.rows).utf8)))
    }

    /// The full reset (RIS) the screen gets before a replay.
    static let reset = Data([0x1B, 0x63])

    // MARK: Drawing

    private static let esc = "\u{1B}["

    private func draw(columns w: Int, rows h: Int) -> String {
        switch content {
        case .claude: Self.claude(w)
        case .vim: Self.vim(w, h)
        case .shell: Self.shell()
        }
    }

    /// Words wrapped at `width` with hard line breaks, as Ink (Claude Code) does.
    private static func wrap(_ text: String, width: Int, first: String, rest: String) -> [String] {
        var lines: [String] = []
        var line = first
        var visible = visibleCount(first)
        var lineIsEmpty = true
        let room = max(8, width)
        for word in text.split(separator: " ") {
            let added = lineIsEmpty ? word.count : word.count + 1
            if visible + added > room, !lineIsEmpty {
                lines.append(line)
                line = rest + word
                visible = rest.count + word.count
            } else {
                line += lineIsEmpty ? String(word) : " " + String(word)
                visible += added
            }
            lineIsEmpty = false
        }
        lines.append(line)
        return lines
    }

    /// Characters a terminal draws (CSI sequences take no cells).
    private static func visibleCount(_ text: String) -> Int {
        var count = 0
        var inEscape = false
        for scalar in text.unicodeScalars {
            if inEscape {
                if (0x40...0x7E).contains(scalar.value), scalar != "[" { inEscape = false }
            } else if scalar == "\u{1B}" {
                inEscape = true
            } else {
                count += 1
            }
        }
        return count
    }

    private static func fit(_ text: String, _ width: Int) -> String {
        let clipped = String(text.prefix(max(0, width)))
        return clipped + String(repeating: " ", count: max(0, width - clipped.count))
    }

    private static func claude(_ w: Int) -> String {
        let accent = esc + "38;5;209m", dim = esc + "2m", off = esc + "0m", bold = esc + "1m"
        let inner = max(4, w - 4)
        var out: [String] = []
        out.append(accent + "╭" + String(repeating: "─", count: max(0, w - 2)) + "╮" + off)
        for text in ["✻ Welcome to Claude Code!", "", "  /help for help, /status for your current setup", "", "  cwd: /Users/dev/src/cmux"] {
            out.append(accent + "│" + off + " " + fit(text, inner) + " " + accent + "│" + off)
        }
        out.append(accent + "╰" + String(repeating: "─", count: max(0, w - 2)) + "╯" + off)
        out.append("")
        out += wrap("why does the phone show the Mac's terminal so small when the Mac pane is wide?", width: w, first: dim + "> ", rest: "  ").map { $0 + off }
        out.append("")
        out += wrap("The phone draws the Mac's grid as the Mac's PTY has it. When the Mac pane is wider than the phone, either the PTY takes the phone's size, or the phone re-wraps each line at its own width.", width: w, first: bold + "⏺" + off + " ", rest: "  ")
        out += wrap("Read cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal/Session/TerminalProjectingSession.swift (239 lines)", width: w, first: "  " + dim + "⎿  ", rest: "     ").map { $0 + off }
        out.append("")
        out += wrap("Update(cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal/Screen/TerminalViewController.swift)", width: w, first: bold + "⏺" + off + " ", rest: "  ")
        out.append("  " + dim + "⎿  " + off + "Updated with 12 additions and 3 removals")
        let diff = [
            (esc + "32m", "+        if !model.isTUI, columns != hostLayout.phoneColumns {"),
            (esc + "32m", "+            model.wideGridsShown += 1"),
            (esc + "31m", "-        syncHostGrid(force: true)"),
        ]
        for (index, (color, text)) in diff.enumerated() {
            out.append("     " + dim + String(1230 + index) + off + " " + color + String(text.prefix(max(4, w - 10))) + off)
        }
        out.append("")
        out += wrap("Both keep the Mac's own size until the phone asks. Shall I add a test for each width?", width: w, first: bold + "⏺" + off + " ", rest: "  ")
        out.append("")
        out.append(dim + String(repeating: "─", count: w) + off)
        out.append("> " + dim + "Try \"add the test\"" + off)
        out.append(dim + String(repeating: "─", count: w) + off)
        let left = "  ? for shortcuts", right = "◯ IDE  "
        out.append(dim + left + String(repeating: " ", count: max(1, w - left.count - right.count)) + right + off)
        return out.joined(separator: "\r\n")
    }

    private static func vim(_ w: Int, _ h: Int) -> String {
        let file = [
            "import Foundation",
            "",
            "/// The phone's own projection of a Mac terminal: the Mac's PTY keeps the pane's grid.",
            "@MainActor",
            "public final class TerminalProjectingSession: TerminalSession {",
            "    public let inner: any TerminalSession",
            "    private var phoneGrid: (columns: Int, rows: Int)?",
            "    private var macGrid: (columns: Int, rows: Int)",
            "",
            "    public func resize(columns: Int, rows: Int) {",
            "        guard columns > 0, rows > 0 else { return }",
            "        phoneGrid = (columns, rows)",
            "        if macClaims { inner.resize(columns: columns, rows: rows) }",
            "    }",
            "}",
        ]
        var out = "\u{1B}[?1049h" + esc + "H" + esc + "2J"
        let body = max(1, h - 2)
        for row in 0..<body {
            out += esc + "\(row + 1);1H"
            if row < file.count {
                let number = String(format: "%3d ", row + 1)
                out += esc + "33m" + number + esc + "0m" + String(file[row].prefix(max(0, w - number.count)))
            } else {
                out += esc + "34m~" + esc + "0m"
            }
        }
        let left = "\"TerminalProjectingSession.swift\" 239L, 8123B", right = "12,9   Top "
        out += esc + "\(h - 1);1H" + esc + "7m" + fit(left + String(repeating: " ", count: max(1, w - left.count - right.count)) + right, w) + esc + "0m"
        out += esc + "\(h);1H" + "-- NORMAL --"
        out += esc + "12;9H"
        return out
    }

    private static func shell() -> String {
        let prompt = esc + "32m~/src/cmux" + esc + "0m $ "
        var lines = [
            prompt + "git log --oneline -4",
            esc + "33m06a84d2a35a5" + esc + "0m cmux-vm: image roll first in production",
            esc + "33mf6fadfbd8ff4" + esc + "0m cmux-next-ios: the soft keyboard never resizes the remote terminal (#41895)",
            esc + "33ma2cd57b64ffa" + esc + "0m cmux-next-ios: app switch, lock and link blips keep the terminal size claim (#41902)",
            esc + "33m50d178e38282" + esc + "0m cmux-next-ios: the phone re-wraps the Mac's terminal itself; the Mac keeps its size",
            prompt + "ls cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal/Session",
            "MockTerminalSession.swift  PendingTerminalSession.swift  TerminalOutputQueue.swift  TerminalReclaimHold.swift  TerminalSession.swift",
            prompt + "swift build 2>&1 | tail -3",
        ]
        for i in 1...6 {
            lines.append("[\(i)/6] Compiling CmuxMobileTerminal TerminalViewController.swift, TerminalModel.swift, TerminalProjectingSession.swift (\(i * 7) ms)")
        }
        lines.append("Build complete! (14.21s)")
        return lines.joined(separator: "\r\n") + "\r\n" + prompt
    }
}
#endif
