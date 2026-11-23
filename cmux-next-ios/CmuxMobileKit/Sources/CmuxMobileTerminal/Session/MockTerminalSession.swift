// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import CmuxMobileTransport
import Foundation

/// A terminal that needs no Mac: a tiny shell with a line editor, scripted
/// output (ls, git log, a long build log for scrolling) and two alternate
/// screen programs (`htop`, `vim`). It plays the owner's role: it receives the
/// bytes Ghostty encodes for keys and writes VT output back.
@MainActor
public final class MockTerminalSession: TerminalSession {
    public private(set) var programName = "zsh"
    public private(set) var isAlternateScreen = false

    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
    private let clock: any Clock<Duration>
    private let playsIntro: Bool
    private var columns = 50
    private var rows = 40
    private var line = ""
    private var program: Program = .shell
    private var tasks: [Task<Void, Never>] = []
    private var busy = false
    private var escapeBuffer: [UInt8] = []
    private var history: [String] = []
    /// The emulated round trip: each write of input reaches the shell this
    /// much later, in order (`-cmux-mobile-term-rtt-ms N`; predictive echo
    /// dogfood and measurement). Zero answers at once.
    private let roundTrip: Duration
    private var inFlight: [(due: ContinuousClock.Instant, bytes: Data)] = []
    private var delivery: Task<Void, Never>?
    /// Plays the Mac's side of a resize (`-CmuxMobileTerminalDemoMac`): the
    /// grid answers a round trip later with the Mac's `resized` (a
    /// `.hostGrid`), a mirror reset (`ESC c`) and one replay of the whole
    /// screen, the way `DaemonTerminalSession` delivers it. Nil: the mock
    /// resizes in place, as a local shell does.
    private let macResize: Duration?
    /// The grid the "Mac" answered last (nil before the first resize).
    private var macGrid: (columns: Int, rows: Int)?
    /// Everything written on the primary screen, for the Mac's replay.
    private var transcript: [String] = []
    private var transcriptBytes = 0
    private var resizeAnswer: Task<Void, Never>?
    private var answers: [(due: ContinuousClock.Instant, columns: Int, rows: Int)] = []
    /// `htop` already running on a Mac pane of this grid when the phone
    /// attaches (the terminal demo's `attach` phase): the attach answers
    /// the app's round trips (`macResize` each, TerminalAttachPlan) after the start, at the grid the phone sent
    /// before it (`attach-surface {cols, rows}`), or the pane's.
    private let attachesTo: (columns: Int, rows: Int)?
    /// The grid the phone gave before the attach went out.
    private var attachSize: (columns: Int, rows: Int)?
    /// The attach went out and its answer has not come yet.
    private var attachInFlight = false
    /// `historywindow`: the older rows the "Mac" holds back until the reader
    /// scrolls near the top of the rows shown, the rows shown, and how long
    /// the older rows' replay takes to come.
    private var heldBack: (older: [String], shown: [String], delay: Int)?
    /// DEBUG bench: the older-row fetches taken (`loadOlderHistory`).
    public private(set) var historyFetches = 0
    /// DEBUG bench: every byte the phone sent this "Mac" (keys, wheel
    /// reports, cursor keys). A local scroll sends none (`tuipan`).
    public private(set) var bytesFromPhone = 0
    /// DEBUG bench: wheel reports and cursor keys `claudefull` scrolled by.
    public private(set) var appScrolls = 0
    /// DEBUG bench (`tuipan`): input goes the way `DaemonTerminalSession`
    /// sends it, one `send` per main-queue turn with everything Ghostty
    /// wrote in it (`scheduleInputDrain`), on a later turn: the finger's
    /// frame never waits on the "Mac". False: each write is taken at once.
    public var batchesInputPerTurn = false
    /// DEBUG bench: the sends to the "Mac" (with `batchesInputPerTurn`, one per turn).
    public private(set) var sends = 0
    private var turnInput: Data?

    private enum Program {
        case shell
        case htop(tick: Int)
        case vim(MockVim)
        /// A full-screen agent like Claude Code: a header box on its first
        /// rows, the transcript, and its input box on the last rows with the
        /// cursor in it.
        case agent
        /// Claude Code in its full-screen mode (`claudefull`): the
        /// alternate screen, the transcript scrolled by the app itself (a
        /// wheel report or a cursor key moves it 3 rows and redraws the
        /// whole screen), a spinner redrawn every 80 ms. `mouse`: it asked
        /// for the mouse (DECSET 1000 + 1006).
        case agentFull(MockClaudeFull)
        /// Claude Code on the primary screen (`claudecli`): its transcript
        /// in the scrollback and its live region (spinner, input box)
        /// redrawn in place every few tens of ms, new rows above it.
        case agentCLI
        /// `claudewheel`: Claude Code's full-screen mode, scrolled by the
        /// wheel (it asks for the mouse), with a live spinner row.
        case agentWheel
    }

    /// DEBUG bench: the wheel reports `claudewheel` has taken, and the rows
    /// they scrolled its transcript.
    public private(set) var wheelReports = 0
    public private(set) var wheelRows = 0
    /// `claudewheel`'s transcript and how many rows it is scrolled up.
    private var fullTranscript: [String] = []
    private var fullOffset = 0
    private var fullTick = 0

    /// `playsIntro`: run `ls -la`, `git log` and a build when the session starts.
    public init(clock: any Clock<Duration> = ContinuousClock(), playsIntro: Bool = true, roundTrip: Duration = .zero,
                macResize: Duration? = nil, attachesTo: (columns: Int, rows: Int)? = nil) {
        self.clock = clock
        self.playsIntro = playsIntro
        self.roundTrip = roundTrip
        self.macResize = macResize
        self.attachesTo = attachesTo
    }

    /// The Mac's grid now, and whether an attach or a resize answer is still
    /// on its way (the demo's `attach` phase: the grid the page must end at).
    public var macState: (columns: Int, rows: Int, inFlight: Bool) {
        let grid = macGrid ?? attachSize ?? attachesTo ?? (columns, rows)
        return (grid.columns, grid.rows, attachInFlight || !answers.isEmpty)
    }

    public var remoteRows: Int? { macGrid?.rows }
    public var remoteColumns: Int? { macGrid?.columns }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        self.handler = handler
        if let pane = attachesTo { return attach(pane: pane) }
        handler(.title("zsh — cmux-next"))
        let intro = playsIntro
        run { session in
            session.write("Last login: Mon Oct 12 09:41:07 on ttys004\r\n")
            session.prompt()
            guard intro else { return }
            for command in ["ls -la", "git log --oneline --graph -n 18", "cargo build --release -p cmux-mobile-host"] {
                try await session.typeCommand(command)
            }
        }
    }

    public func send(_ bytes: Data) {
        bytesFromPhone += bytes.count
        guard batchesInputPerTurn else {
            sends += 1
            return forward(bytes)
        }
        if turnInput == nil {
            turnInput = Data()
            Task { [weak self] in
                guard let self, let batch = self.turnInput else { return }
                self.turnInput = nil
                self.sends += 1
                self.forward(batch)
            }
        }
        turnInput?.append(bytes)
    }

    private func forward(_ bytes: Data) {
        guard roundTrip > .zero else { return deliver(bytes) }
        inFlight.append((ContinuousClock.now + roundTrip, bytes))
        guard delivery == nil else { return }
        delivery = Task { [weak self] in
            while let self, let next = self.inFlight.first {
                try? await Task.sleep(until: next.due, clock: .continuous)
                guard !Task.isCancelled else { return }
                self.inFlight.removeFirst()
                self.deliver(next.bytes)
            }
            self?.delivery = nil
        }
    }

    private func deliver(_ bytes: Data) {
        if case .agentFull(var full) = program {
            // The app reads its own wheel reports and cursor keys.
            let before = full.scrolls
            if full.handle(bytes) { exitProgram(); return }
            appScrolls += full.scrolls - before
            program = .agentFull(full)
            write(full.render(columns: columns, rows: rows))
            return
        }
        for byte in bytes { receive(byte) }
        // A lone ESC at the end of a write is the Escape key, not a sequence start.
        if escapeBuffer == [0x1B] {
            escapeBuffer.removeAll()
            handle(.escape)
        }
    }

    public func resize(columns: Int, rows: Int) {
        if attachesTo != nil, handler == nil || attachInFlight {
            // Before the attach answered: the attach carries it.
            if columns > 0, rows > 0 { attachSize = (columns, rows) }
            return
        }
        if let macResize {
            answerResize(columns: columns, rows: rows, after: macResize)
            return
        }
        guard columns > 0, rows > 0, columns != self.columns || rows != self.rows else { return }
        self.columns = columns
        self.rows = rows
        switch program {
        case .shell: break
        case .htop(let tick): drawHtop(tick: tick)
        case .vim(var vim):
            write(vim.render(columns: columns, rows: rows))
            program = .vim(vim)
        case .agent: drawAgent()
        case .agentFull(let full): write(full.render(columns: columns, rows: rows))
        case .agentCLI: break
        case .agentWheel: drawFull()
        }
    }

    /// The Mac's answer to a resize: its grid, a mirror reset and one replay
    /// (the primary screen's history, then the program's screen at the new
    /// size), in one turn of the main queue like a `resized` event line.
    /// Every resize is answered, in order, as the daemon does (two toggles
    /// inside a round trip get two answers).
    private func answerResize(columns: Int, rows: Int, after delay: Duration) {
        guard columns > 0, rows > 0 else { return }
        answers.append((ContinuousClock.now + delay, columns, rows))
        guard resizeAnswer == nil else { return }
        let clock = ContinuousClock()
        resizeAnswer = Task { [weak self] in
            while let self, let next = self.answers.first {
                try? await clock.sleep(until: next.due)
                guard !Task.isCancelled else { return }
                self.answers.removeFirst()
                self.answer(columns: next.columns, rows: next.rows)
            }
            self?.resizeAnswer = nil
        }
    }

    /// The attach into `htop` on a pane of `pane`: the app's round trips later, the
    /// Mac's grid (the phone's, when it sent one), a mirror reset and one
    /// replay (the shell's history, then htop's screen), as
    /// `DaemonTerminalSession` delivers an attach, then `.attached`.
    private func attach(pane: (columns: Int, rows: Int)) {
        attachInFlight = true
        handler?(.connection(.connecting(mac: "Mac")))
        // The round trips `DaemonTerminalSession.attach()` makes before the
        // Mac's answer (TerminalAttachPlan): one when the phone gave its grid
        // before the attach (it rides `set-client-info` + `identify`), two
        // without one (`identify` first, then `attach-surface`).
        let plan = TerminalAttachPlan.plan(firstAttach: true, claimsSize: true, size: attachSize)
        let delay = (macResize ?? .zero) * plan.roundTrips
        let task = Task { [weak self] in
            try? await ContinuousClock().sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            let grid = self.attachSize ?? pane
            self.columns = grid.columns
            self.rows = grid.rows
            self.macGrid = grid
            var history = "Last login: Mon Oct 12 09:41:07 on ttys004\r\n"
            for line in 1...60 { history += "history \(line): \(String(repeating: "=", count: 40))\r\n" }
            history += "\u{1B}[32m❯\u{1B}[0m htop\r\n"
            self.transcript = [history]
            self.transcriptBytes = history.utf8.count
            self.program = .htop(tick: 0)
            self.isAlternateScreen = true
            self.programName = "htop"
            self.attachInFlight = false
            self.handler?(.hostGrid(columns: grid.columns, rows: grid.rows))
            self.handler?(.output(Data("\u{1B}c".utf8)))
            self.handler?(.alternateScreen(true))
            self.handler?(.output(Data((history + "\u{1B}[?1049h\u{1B}[H\u{1B}[2J" + Self.htopMouse
                + MockHtop.render(columns: grid.columns, rows: grid.rows, tick: 0)).utf8)))
            self.handler?(.title("htop — cmux-next"))
            self.handler?(.connection(.attached))
        }
        tasks.append(task)
    }

    /// The mouse reporting htop turns on (and the Mac's replay keeps).
    static let htopMouse = "\u{1B}[?1000h\u{1B}[?1006h"

    private func answer(columns: Int, rows: Int) {
        if let grid = macGrid, grid.columns == columns, grid.rows == rows { return }
        self.columns = columns
        self.rows = rows
        macGrid = (columns, rows)
        handler?(.hostGrid(columns: columns, rows: rows))
        handler?(.output(Data("\u{1B}c".utf8)))
        var replay = transcript.joined()
        switch program {
        case .shell: break
        case .htop(let tick):
            replay += "\u{1B}[?1049h\u{1B}[H\u{1B}[2J" + Self.htopMouse + MockHtop.render(columns: columns, rows: rows, tick: tick)
        case .vim(var vim):
            replay += "\u{1B}[?1049h\u{1B}[H\u{1B}[2J" + vim.render(columns: columns, rows: rows)
            program = .vim(vim)
        case .agent:
            replay += "\u{1B}[?1049h" + agentScreen()
        case .agentFull(let full):
            replay += "\u{1B}[?1049h" + (full.mouse ? Self.htopMouse : "") + full.render(columns: columns, rows: rows)
        case .agentCLI: break
        case .agentWheel:
            replay += "\u{1B}[?1049h\u{1B}[H\u{1B}[2J" + Self.htopMouse
        }
        handler?(.output(Data(replay.utf8)))
        if case .agentWheel = program { drawFull() }
    }

    /// `historywindow`'s older rows: the Mac's reset and replay, `delay` ms
    /// after the ask, like `DaemonTerminalSession.loadOlderHistory()`.
    @discardableResult
    public func loadOlderHistory() -> Bool {
        guard let held = heldBack else { return false }
        heldBack = nil
        historyFetches += 1
        let task = Task { [weak self] in
            try? await self?.pause(held.delay)
            guard let self, !Task.isCancelled else { return }
            self.handler?(.output(TerminalReclaimHold.reset))
            self.handler?(.output(Data((held.older + held.shown).map { $0 + "\r\n" }.joined().utf8)))
            self.prompt()
        }
        tasks.append(task)
        return true
    }

    public func stop() {
        resizeAnswer?.cancel()
        resizeAnswer = nil
        answers.removeAll()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        delivery?.cancel()
        delivery = nil
        inFlight.removeAll()
        handler = nil
    }

    // MARK: Output

    private func write(_ text: String) {
        if macResize != nil, !isAlternateScreen { record(text) }
        let data = Data(text.utf8)
        // No link in mock mode: the shell's output is what the transport would deliver.
        ReceivedByteCount.shared.add(data.count)
        handler?(.output(data))
    }

    /// The primary screen's history the Mac would replay (its last 256 KB).
    private func record(_ text: String) {
        transcript.append(text)
        transcriptBytes += text.utf8.count
        while transcriptBytes > 256 << 10, transcript.count > 1 {
            transcriptBytes -= transcript.removeFirst().utf8.count
        }
    }

    private func setAlternate(_ on: Bool, program name: String) {
        isAlternateScreen = on
        programName = name
        // Not part of the primary screen's history (the Mac's replay).
        handler?(.output(Data((on ? "\u{1B}[?1049h\u{1B}[H\u{1B}[2J" : "\u{1B}[?1049l").utf8)))
        handler?(.alternateScreen(on))
        handler?(.title(on ? "\(name) — cmux-next" : "zsh — cmux-next"))
    }

    private func prompt() {
        write("\r\n\u{1B}[36m~/cmux-next\u{1B}[0m on \u{1B}[35m\u{E0A0} main\u{1B}[0m \u{1B}[2m[!2 ?1]\u{1B}[0m\r\n\u{1B}[32m❯\u{1B}[0m ")
    }

    private func run(_ body: @escaping @MainActor (MockTerminalSession) async throws -> Void) {
        busy = true
        let task = Task { [weak self] in
            guard let self else { return }
            try? await body(self)
            self.busy = false
        }
        tasks.append(task)
    }

    private func pause(_ milliseconds: Int) async throws {
        try await clock.sleep(for: .milliseconds(milliseconds))
    }

    /// Types `command` at the prompt like a person, then runs it.
    private func typeCommand(_ command: String) async throws {
        try await pause(500)
        for character in command {
            write(String(character))
            try await pause(Int.random(in: 25...70))
        }
        try await pause(250)
        write("\r\n")
        try await execute(command)
    }

    // MARK: Input

    private func receive(_ byte: UInt8) {
        if !escapeBuffer.isEmpty || byte == 0x1B {
            escapeBuffer.append(byte)
            if let key = MockKey.parse(escapeBuffer) {
                escapeBuffer.removeAll()
                handle(key)
            } else if escapeBuffer.count > 32 {
                escapeBuffer.removeAll()
            }
            return
        }
        handle(MockKey(byte: byte))
    }

    private func handle(_ key: MockKey) {
        switch program {
        case .shell: shellKey(key)
        case .htop: if key == .char("q") || key == .control("c") || key == .f10 { exitProgram() }
        case .vim(var vim):
            if vim.handle(key) == .quit {
                exitProgram()
            } else {
                write(vim.render(columns: columns, rows: rows))
                program = .vim(vim)
            }
        case .agent: if key == .control("c") || key == .escape { exitProgram() }
        case .agentFull: break
        case .agentCLI: if key == .control("c") { exitProgram() }
        case .agentWheel:
            if key == .control("c") || key == .escape { return exitProgram() }
            if case .wheel(let up) = key {
                // Claude Code scrolls its transcript three rows a report.
                let bottom = max(0, fullTranscript.count - fullRows)
                let next = min(bottom, max(0, fullOffset + (up ? 3 : -3)))
                wheelReports += 1
                wheelRows += abs(next - fullOffset)
                guard next != fullOffset else { return }
                fullOffset = next
                drawFull()
            }
        }
    }

    private func shellKey(_ key: MockKey) {
        guard !busy else {
            if key == .control("c") { cancelRunning() }
            return
        }
        switch key {
        case .enter:
            let command = line.trimmingCharacters(in: .whitespaces)
            line = ""
            write("\r\n")
            if !command.isEmpty { history.append(command) }
            run { try await $0.execute(command) }
        case .backspace:
            guard !line.isEmpty else { return }
            line.removeLast()
            write("\u{8} \u{8}")
        case .control("c"):
            line = ""
            write("^C")
            prompt()
        case .control("l"):
            write("\u{1B}[H\u{1B}[2J")
            write("\u{1B}[32m❯\u{1B}[0m \(line)")
        case .control("d"):
            if line.isEmpty { write("\r\n\u{1B}[2m(mock) exit is disabled\u{1B}[0m"); prompt() }
        case .up:
            guard let last = history.last else { return }
            write(String(repeating: "\u{8} \u{8}", count: line.count))
            line = last
            write(last)
        case .char(let character):
            line.append(character)
            write(String(character))
        case .text(let text):
            line += text
            write(text)
        default:
            break
        }
    }

    private func cancelRunning() {
        tasks.last?.cancel()
        busy = false
        write("^C")
        prompt()
    }

    private func exitProgram() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        program = .shell
        setAlternate(false, program: "zsh")
        busy = false
        prompt()
    }

    // MARK: Commands

    private func execute(_ command: String) async throws {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.first else { return prompt() }
        switch name {
        case "ls": try await stream(MockOutput.ls(long: parts.contains { $0.hasPrefix("-") && $0.contains("l") }))
        case "git" where parts.dropFirst().first == "log": try await stream(MockOutput.gitLog)
        case "git" where parts.dropFirst().first == "status": try await stream(MockOutput.gitStatus)
        case "cargo", "make", "build": try await stream(MockOutput.buildLog(), lineDelay: 4, batch: 3)
        case "stream":
            // stream [LINES=3000] [MS=20]: numbered rows like the rig's stream20.py,
            // for timing a drag while output streams (termqa G-04).
            let count = parts.count > 1 ? Int(parts[1]) ?? 3000 : 3000
            let delay = parts.count > 2 ? Int(parts[2]) ?? 20 : 20
            // Each row is made as it is written: `stream 1000000 20` held a
            // million rows (about 90 MB) in memory for as long as it ran.
            let lines = (1...max(1, count)).lazy.map { String(format: "#%07d \u{1B}[3%dmstreamed row\u{1B}[0m %@", $0, 1 + $0 % 6, String(repeating: "x", count: $0 % 30)) }
            try await stream(lines, lineDelay: delay)
        case "codex":
            // An inline TUI like Codex CLI's fresh session (termqa D1): a short
            // document whose cursor sits in an input box with rows below it.
            // `codex N`: N rows of an earlier answer above the box.
            let rule = String(repeating: "-", count: max(10, min(40, columns - 2)))
            let earlier = (0..<(parts.count > 1 ? Int(parts[1]) ?? 0 : 0)).map { "• earlier answer row \($0 + 1)\r\n" }.joined()
            write("\u{1B}[H\u{1B}[2J\u{1B}[3J" + earlier + "╭\(rule)╮\r\n│ >_ OpenAI Codex (mock)\r\n│ model: gpt-6 high   /model to change\r\n│ directory: ~/cmux-next\r\n╰\(rule)╯\r\n\r\n"
                + "  To get started, describe a task or try one of these commands:\r\n\r\n  /init - create an AGENTS.md file\r\n  /status - show current session configuration\r\n\r\n"
                + "› Ask Codex to do anything\r\n\r\n  ? for shortcuts                          100% context left")
            write("\u{1B}[2A\r\u{1B}[2C")
            return
        case "claudeinline":
            // claudeinline [MS=80] [CLEAR_EVERY=0] [ROWS=60]: Claude Code CLI's inline
            // screen (Leo, 2026-11-21: "this claude code cli is often slow to
            // scroll"). It draws on the primary screen: transcript rows go
            // into the scrollback, and every MS ms the spinner, input box and
            // status rows below them are redrawn in place (cursor up, erase
            // line). Every CLEAR_EVERY redraws it clears the screen and its
            // scrollback and prints everything again, as Claude Code does
            // when its screen overflows. ROWS: the transcript's rows at the
            // start (a long session's reprint is its whole transcript). Runs
            // until Ctrl-C.
            let delay = max(8, parts.count > 1 ? Int(parts[1]) ?? 80 : 80)
            let clearEvery = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            let startRows = max(1, parts.count > 3 ? Int(parts[3]) ?? 60 : 60)
            try await claudeInline(delay: delay, clearEvery: clearEvery, startRows: startRows)
        case "historywindow":
            // historywindow [SHOWN=150] [OLDER=2000] [MS=60]: a Mac terminal
            // attached with its latest rows first (DaemonTerminalSession): SHOWN
            // rows now, and OLDER more once the reader scrolls near the top,
            // MS ms later, as the Mac delivers them: a mirror reset (ESC c)
            // and one replay of the whole window.
            let shown = max(1, parts.count > 1 ? Int(parts[1]) ?? 150 : 150)
            let older = max(1, parts.count > 2 ? Int(parts[2]) ?? 2000 : 2000)
            let delay = max(0, parts.count > 3 ? Int(parts[3]) ?? 60 : 60)
            func row(_ index: Int) -> String { "history row \(index) " + String(repeating: "lorem ", count: 1 + index % 7) }
            let rows = (older + 1...older + shown).map(row)
            heldBack = ((1...older).map(row), rows, delay)
            write(rows.map { $0 + "\r\n" }.joined())
        case "clear": write("\u{1B}[H\u{1B}[2J")
        case "echo": write(parts.dropFirst().joined(separator: " ") + "\r\n")
        case "cat": try await stream(MockOutput.file(named: parts.dropFirst().first ?? ""))
        case "help": try await stream(MockOutput.help)
        case "htop", "top":
            busy = false
            program = .htop(tick: 0)
            setAlternate(true, program: "htop")
            // htop reports the mouse (button events, SGR coordinates).
            handler?(.output(Data(Self.htopMouse.utf8)))
            startHtopTicker()
            return
        case "claudewheel":
            // claudewheel [MS=50]: Claude Code CLI's full-screen mode (Leo,
            // 2026-11-21: "this claude code cli is often slow to scroll up
            // and down from ios"). On the alternate screen, it reports the
            // mouse: a drag on the phone is wheel reports, each one redraws
            // the transcript three rows on, and every MS ms the spinner row
            // is redrawn (a transcript row every third tick). Ctrl-C quits.
            busy = false
            program = .agentWheel
            setAlternate(true, program: "claude")
            handler?(.output(Data(Self.htopMouse.utf8)))
            fullTranscript = (1...400).map(Self.fullRow)
            fullOffset = 0
            fullTick = 0
            drawFull()
            let delay = max(8, parts.count > 1 ? Int(parts[1]) ?? 50 : 50)
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    do { try await self?.pause(delay) } catch { return }
                    guard let self, case .agentWheel = self.program else { return }
                    self.fullTick += 1
                    if self.fullTick % 3 == 0 {
                        self.fullTranscript.append(Self.fullRow(self.fullTranscript.count + 1))
                        // Scrolled up, the view keeps its rows.
                        if self.fullOffset > 0 { self.fullOffset += 1 } else { self.drawFull(); continue }
                    }
                    self.write(self.fullSpinner())
                }
            })
            return
        case "claude":
            busy = false
            program = .agent
            setAlternate(true, program: "claude")
            drawAgent()
            return
        case "claudecli":
            // claudecli [ROWS=1500] [MS=80]: Claude Code on the primary
            // screen. ROWS transcript rows go to the scrollback, then its
            // live region (a spinner and the input box, 5 rows) is redrawn
            // in place every MS ms the way Ink does (cursor up, erase,
            // rewrite), with a new transcript row above it every 6th frame.
            let count = max(1, parts.count > 1 ? Int(parts[1]) ?? 1500 : 1500)
            let delay = max(10, parts.count > 2 ? Int(parts[2]) ?? 80 : 80)
            busy = false
            program = .agentCLI
            programName = "claude"
            handler?(.title("claude — cmux-next"))
            write((1...count).map { MockClaudeFull.transcriptRow($0) + "\r\n" }.joined())
            let rule = String(repeating: "\u{2500}", count: max(10, min(60, columns - 2)))
            write(Self.claudeRegion(tick: 0, rule: rule))
            let task = Task { [weak self] in
                var tick = 1, next = count + 1
                while !Task.isCancelled {
                    do { try await self?.pause(delay) } catch { return }
                    guard let self, case .agentCLI = self.program else { return }
                    // Up to the region's first row, erase it, then rows above it.
                    var out = "\r\u{1B}[3A\u{1B}[J"
                    if tick % 6 == 0 {
                        out += MockClaudeFull.transcriptRow(next) + "\r\n"
                        next += 1
                    }
                    self.write(out + Self.claudeRegion(tick: tick, rule: rule))
                    tick += 1
                }
            }
            tasks.append(task)
            return
        case "claudefull":
            // claudefull [ROWS=1500] [mouse|keys] [stream=MS]: Claude Code's
            // full-screen mode on the alternate screen; `mouse` asks for the
            // mouse. `stream=MS`: a new transcript row and a whole-screen
            // redraw every MS ms (a reply streaming in), else the spinner
            // alone every 80 ms.
            let count = max(1, parts.count > 1 ? Int(parts[1]) ?? 1500 : 1500)
            let mouse = !parts.contains("keys")
            let stream = parts.first { $0.hasPrefix("stream=") }.flatMap { Int($0.dropFirst(7)) }.map { max(5, $0) }
            busy = false
            let full = MockClaudeFull(rows: count, mouse: mouse)
            program = .agentFull(full)
            setAlternate(true, program: "claude")
            if mouse { handler?(.output(Data(Self.htopMouse.utf8))) }
            write(full.render(columns: columns, rows: rows))
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await self?.pause(stream ?? 80) } catch { return }
                    guard let self, case .agentFull(var full) = self.program else { return }
                    full.tick += 1
                    if stream != nil {
                        // A scrolled-back view stays on its rows as new ones come.
                        full.rows += 1
                        if full.offset > 0 { full.offset += 1 }
                    }
                    self.program = .agentFull(full)
                    self.write(stream != nil ? full.render(columns: self.columns, rows: self.rows) : full.statusRow(rows: self.rows))
                }
            }
            tasks.append(task)
            return
        case "vim", "vi", "nvim":
            busy = false
            let file = parts.dropFirst().first ?? "README.md"
            var vim = MockVim(file: file, lines: MockOutput.fileLines(named: file))
            setAlternate(true, program: "vim")
            write(vim.render(columns: columns, rows: rows))
            program = .vim(vim)
            return
        default:
            write("zsh: command not found: \(name)\r\n")
        }
        prompt()
    }

    /// Writes `lines` `batch` at a time, `lineDelay` ms apart. Takes them as
    /// they come, so a long lazy stream is never held whole.
    private func stream<Lines: Sequence<String>>(_ lines: Lines, lineDelay: Int = 12, batch: Int = 1) async throws {
        var chunk: [String] = []
        for line in lines {
            chunk.append(line)
            guard chunk.count >= batch else { continue }
            write(chunk.map { $0 + "\r\n" }.joined())
            chunk.removeAll(keepingCapacity: true)
            try await pause(lineDelay)
        }
        guard !chunk.isEmpty else { return }
        write(chunk.map { $0 + "\r\n" }.joined())
        try await pause(lineDelay)
    }

    /// `claudecli`'s live region: a blank row, the spinner, the input box
    /// (5 rows, the cursor after its prompt on the 4th).
    static func claudeRegion(tick: Int, rule: String) -> String {
        let spinner = ["\u{00B7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}"][tick % 6]
        return "\r\n\u{1B}[33m\(spinner)\u{1B}[0m Thinking\u{2026} (\(tick / 12)s \u{00B7} esc to interrupt)\r\n"
            + "\u{256D}\(rule)\u{256E}\r\n\u{2502} > \r\n\u{2570}\(rule)\u{256F}\u{1B}[1A\r\u{1B}[4C"
    }

    /// `claudeinline`'s loop: a transcript row every few frames, the live
    /// region (7 rows) redrawn every `delay` ms.
    private func claudeInline(delay: Int, clearEvery: Int, startRows: Int) async throws {
        let rule = String(repeating: "\u{2500}", count: max(10, min(80, columns - 2)))
        let spinner = ["\u{00B7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}"]
        var transcript: [String] = []
        func row(_ index: Int) -> String {
            index % 5 == 0
                ? "\u{1B}[32m\u{23FA}\u{1B}[0m \u{1B}[1mUpdate\u{1B}[0m(Sources/File\(index).swift) answer row \(index)"
                : "  \u{23BF} transcript row \(index) " + String(repeating: "lorem ", count: 1 + index % 9)
        }
        func live(_ tick: Int) -> String {
            "\r\n\u{1B}[33m\(spinner[tick % spinner.count])\u{1B}[0m Thinking\u{2026} (\(tick / 10)s \u{00B7} \u{2191} \(tick * 37) tokens \u{00B7} esc to interrupt)\r\n\r\n"
                + "\u{256D}\(rule)\u{256E}\r\n\u{2502} > \r\n\u{2570}\(rule)\u{256F}\r\n"
                + "  \u{1B}[2m? for shortcuts\u{1B}[0m"
        }
        // The live region is 7 rows: up 6 from its last row, then erase it.
        let liveRows = 7
        let erase = "\r\u{1B}[\(liveRows - 1)A\u{1B}[J"
        write("\u{1B}[33m\u{273B}\u{1B}[0m Welcome to Claude Code (mock)\r\n")
        for index in 1...startRows { transcript.append(row(index)) }
        write(transcript.map { $0 + "\r\n" }.joined())
        write(live(0))
        var tick = 1
        while !Task.isCancelled {
            try await pause(delay)
            var out = erase
            if clearEvery > 0, tick % clearEvery == 0 {
                out = "\u{1B}[H\u{1B}[2J\u{1B}[3J" + transcript.map { $0 + "\r\n" }.joined()
            }
            if tick % 3 == 0 {
                let next = row(transcript.count + 1)
                transcript.append(next)
                out += next + "\r\n"
            }
            write(out + live(tick))
            tick += 1
        }
    }

    // MARK: claudewheel

    /// The transcript's rows on screen: below the 3-row header, above the
    /// spinner row, a blank and the 3-row input box.
    private var fullRows: Int { max(1, rows - 8) }

    private static func fullRow(_ index: Int) -> String {
        index % 5 == 0
            ? "\u{1B}[32m\u{23FA}\u{1B}[0m \u{1B}[1mUpdate\u{1B}[0m(Sources/File\(index).swift) answer row \(index)"
            : "  \u{23BF} transcript row \(index) " + String(repeating: "lorem ", count: 1 + index % 9)
    }

    private func fullSpinner() -> String {
        let spinner = ["\u{00B7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}"]
        return "\u{1B}[\(rows - 4);1H\u{1B}[2K\u{1B}[33m\(spinner[fullTick % spinner.count])\u{1B}[0m Thinking\u{2026} (\(fullTick / 20)s \u{00B7} \u{2191} \(fullTick * 37) tokens)"
            + "\u{1B}[\(rows - 1);5H"
    }

    /// The whole screen, as Claude Code's full-screen renderer redraws it.
    private func drawFull() {
        let rule = String(repeating: "\u{2500}", count: max(10, min(80, columns - 2)))
        var out = "\u{1B}[H"
        out += "\u{1B}[1;1H\u{1B}[2K\u{256D}\(rule)\u{256E}"
        out += "\u{1B}[2;1H\u{1B}[2K\u{2502} \u{1B}[33m\u{273B}\u{1B}[0m Claude Code (mock)  ~/cmux-next"
        out += "\u{1B}[3;1H\u{1B}[2K\u{2570}\(rule)\u{256F}"
        let end = fullTranscript.count - fullOffset
        let start = max(0, end - fullRows)
        for (index, line) in fullTranscript[start..<end].enumerated() {
            out += "\u{1B}[\(4 + index);1H\u{1B}[2K" + line
        }
        out += "\u{1B}[\(rows - 2);1H\u{1B}[2K\u{256D}\(rule)\u{256E}"
        out += "\u{1B}[\(rows - 1);1H\u{1B}[2K\u{2502} > "
        out += "\u{1B}[\(rows);1H\u{1B}[2K\u{2570}\(rule)\u{256F}"
        write(out + fullSpinner())
    }

    // MARK: htop

    /// The agent program's screen at the current grid: its header box on
    /// rows 1-3, transcript rows, and the input box on the last three rows
    /// with the cursor after its prompt.
    private func drawAgent() { write(agentScreen()) }

    /// The agent screen's bytes at the current grid.
    private func agentScreen() -> String {
        let rule = String(repeating: "\u{2500}", count: max(10, min(60, columns - 2)))
        var out = "\u{1B}[H\u{1B}[2J"
        out += "\u{1B}[1;1H\u{256D}\(rule)\u{256E}"
        out += "\u{1B}[2;1H\u{2502} \u{1B}[33m\u{273B}\u{1B}[0m Claude Code (mock)  ~/cmux-next"
        out += "\u{1B}[3;1H\u{2570}\(rule)\u{256F}"
        let last = max(4, rows - 3)
        if last >= 5 {
            for row in 5...last {
                out += "\u{1B}[\(row);1H" + (row % 4 == 1 ? "\u{1B}[32m\u{23FA}\u{1B}[0m answer \(row - 4)" : "  transcript row \(row - 4)")
            }
        }
        out += "\u{1B}[\(rows - 2);1H\u{256D}\(rule)\u{256E}"
        out += "\u{1B}[\(rows - 1);1H\u{2502} > "
        out += "\u{1B}[\(rows);1H\u{2570}\(rule)\u{256F}"
        out += "\u{1B}[\(rows - 1);5H"
        return out
    }

    private func startHtopTicker() {
        let task = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, case .htop = self.program else { return }
                self.drawHtop(tick: tick)
                self.program = .htop(tick: tick)
                tick += 1
                do { try await self.pause(900) } catch { return }
            }
        }
        tasks.append(task)
    }

    private func drawHtop(tick: Int) {
        write(MockHtop.render(columns: columns, rows: rows, tick: tick))
    }
}

/// `claudefull`: Claude Code's full-screen mode. The app holds the
/// transcript and draws the part it scrolled to; the phone holds only the
/// screen. A wheel report (SGR buttons 64/65) or a cursor key moves it 3 rows.
struct MockClaudeFull: Equatable {
    var rows: Int
    let mouse: Bool
    /// Rows scrolled up from the newest.
    var offset = 0
    var tick = 0
    /// Wheel reports and cursor keys taken (DEBUG bench).
    var scrolls = 0

    static func transcriptRow(_ index: Int) -> String {
        switch index % 5 {
        case 0: "\u{1B}[32m\u{23FA}\u{1B}[0m answer \(index): " + String(repeating: "lorem ", count: 1 + index % 6)
        case 1: "  \u{23BF} Read cmux-next-ios/Sources/File\(index).swift (\(index % 300) lines)"
        case 2: "\u{1B}[2m  \u{2026} +\(index % 40) lines (ctrl+o to expand)\u{1B}[0m"
        default: "  transcript row \(index) " + String(repeating: "ipsum ", count: index % 7)
        }
    }

    /// Takes the phone's bytes; true when it quits (ctrl-c).
    mutating func handle(_ bytes: Data) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
        if bytes.contains(0x03) { return true }
        let up = text.components(separatedBy: "\u{1B}[<64;").count - 1
            + text.components(separatedBy: "\u{1B}[A").count - 1 + text.components(separatedBy: "\u{1B}OA").count - 1
        let down = text.components(separatedBy: "\u{1B}[<65;").count - 1
            + text.components(separatedBy: "\u{1B}[B").count - 1 + text.components(separatedBy: "\u{1B}OB").count - 1
        scrolls += up + down
        offset = max(0, min(rows, offset + 3 * (up - down)))
        return false
    }

    /// The status row (the spinner), redrawn in place.
    func statusRow(rows screen: Int) -> String {
        let spinner = ["\u{00B7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}"][tick % 6]
        return "\u{1B}7\u{1B}[\(max(1, screen - 3));1H\u{1B}[2K\u{1B}[33m\(spinner)\u{1B}[0m Thinking\u{2026} (\(tick / 12)s)\u{1B}8"
    }

    /// The whole screen: a header row, the transcript ending `offset` rows
    /// above the newest, the status row and the input box.
    func render(columns: Int, rows screen: Int) -> String {
        let rule = String(repeating: "\u{2500}", count: max(10, min(60, columns - 2)))
        let body = max(1, screen - 5)
        let last = max(1, rows - offset)
        let first = max(1, last - body + 1)
        var out = "\u{1B}[H\u{1B}[2J\u{1B}[1;1H\u{1B}[33m\u{273B}\u{1B}[0m Claude Code (mock full screen)"
        for (line, index) in (first...last).enumerated() {
            out += "\u{1B}[\(line + 2);1H" + String(Self.transcriptRow(index).prefix(columns + 12))
        }
        out += statusRow(rows: screen)
        out += "\u{1B}[\(screen - 2);1H\u{256D}\(rule)\u{256E}\u{1B}[\(screen - 1);1H\u{2502} > \u{1B}[\(screen);1H\u{2570}\(rule)\u{256F}"
        return out + "\u{1B}[\(screen - 1);5H"
    }
}

/// One decoded input key (what Ghostty encoded for a key press).
enum MockKey: Equatable {
    case char(Character), text(String), control(Character)
    case enter, backspace, tab, escape, up, down, left, right, f10, other
    /// An SGR wheel report (`ESC [ < 64;x;y M` up, 65 down).
    case wheel(up: Bool)

    init(byte: UInt8) {
        switch byte {
        case 0x0D, 0x0A: self = .enter
        case 0x7F, 0x08: self = .backspace
        case 0x09: self = .tab
        case 0x01...0x1A: self = .control(Character(UnicodeScalar(byte + 0x60)))
        case 0x20...0x7E: self = .char(Character(UnicodeScalar(byte)))
        default: self = byte >= 0x80 ? .text(String(decoding: [byte], as: UTF8.self)) : .other
        }
    }

    /// A complete escape sequence, or nil while more bytes are needed.
    static func parse(_ bytes: [UInt8]) -> MockKey? {
        guard bytes.first == 0x1B else { return .other }
        if bytes.count == 1 { return nil }
        if bytes[1] != 0x5B, bytes[1] != 0x4F { return .escape }
        if bytes.count >= 3, bytes[1] == 0x5B, bytes[2] == 0x3C {
            // SGR mouse: ESC [ < button ; x ; y M|m.
            guard let last = bytes.last, last == 0x4D || last == 0x6D else { return nil }
            let fields = String(decoding: bytes[3..<(bytes.count - 1)], as: UTF8.self).split(separator: ";")
            switch fields.first.flatMap({ Int($0) }) {
            case 64: return .wheel(up: true)
            case 65: return .wheel(up: false)
            default: return .other
            }
        }
        guard bytes.count >= 3, let last = bytes.last, (0x40...0x7E).contains(last) || bytes.count > 2 && bytes[1] == 0x4F else { return nil }
        switch last {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x7E: return bytes.starts(with: [0x1B, 0x5B, 0x32, 0x31]) ? .f10 : .other
        default: return .other
        }
    }
}
#endif
