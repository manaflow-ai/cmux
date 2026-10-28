// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
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

    private enum Program {
        case shell
        case htop(tick: Int)
        case vim(MockVim)
    }

    /// `playsIntro`: run `ls -la`, `git log` and a build when the session starts.
    public init(clock: any Clock<Duration> = ContinuousClock(), playsIntro: Bool = true) {
        self.clock = clock
        self.playsIntro = playsIntro
    }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        self.handler = handler
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
        for byte in bytes { receive(byte) }
        // A lone ESC at the end of a write is the Escape key, not a sequence start.
        if escapeBuffer == [0x1B] {
            escapeBuffer.removeAll()
            handle(.escape)
        }
    }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0, columns != self.columns || rows != self.rows else { return }
        self.columns = columns
        self.rows = rows
        switch program {
        case .shell: break
        case .htop(let tick): drawHtop(tick: tick)
        case .vim(var vim):
            write(vim.render(columns: columns, rows: rows))
            program = .vim(vim)
        }
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        handler = nil
    }

    // MARK: Output

    private func write(_ text: String) {
        handler?(.output(Data(text.utf8)))
    }

    private func setAlternate(_ on: Bool, program name: String) {
        isAlternateScreen = on
        programName = name
        write(on ? "\u{1B}[?1049h\u{1B}[H\u{1B}[2J" : "\u{1B}[?1049l")
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
            } else if escapeBuffer.count > 8 {
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
            let lines = (1...max(1, count)).map { String(format: "#%07d \u{1B}[3%dmstreamed row\u{1B}[0m %@", $0, 1 + $0 % 6, String(repeating: "x", count: $0 % 30)) }
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
        case "clear": write("\u{1B}[H\u{1B}[2J")
        case "echo": write(parts.dropFirst().joined(separator: " ") + "\r\n")
        case "cat": try await stream(MockOutput.file(named: parts.dropFirst().first ?? ""))
        case "help": try await stream(MockOutput.help)
        case "htop", "top":
            busy = false
            program = .htop(tick: 0)
            setAlternate(true, program: "htop")
            startHtopTicker()
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

    private func stream(_ lines: [String], lineDelay: Int = 12, batch: Int = 1) async throws {
        var index = 0
        while index < lines.count {
            let chunk = lines[index..<min(index + batch, lines.count)]
            write(chunk.map { $0 + "\r\n" }.joined())
            index += batch
            try await pause(lineDelay)
        }
    }

    // MARK: htop

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

/// One decoded input key (what Ghostty encoded for a key press).
enum MockKey: Equatable {
    case char(Character), text(String), control(Character)
    case enter, backspace, tab, escape, up, down, left, right, f10, other

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
