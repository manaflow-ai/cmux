// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import Foundation

/// Scripted output of the mock shell. Paths and URLs in it feed the artifacts list.
struct MockOutput {
    private static let esc = "\u{1B}["

    private static func sgr(_ code: String, _ text: String) -> String { "\(esc)\(code)m\(text)\(esc)0m" }

    static func ls(long: Bool) -> [String] {
        let entries: [(String, Bool, String, String)] = [
            (".github", true, "4.0K", "Oct  9 18:22"), ("Cargo.lock", false, "212K", "Oct 12 09:12"),
            ("Cargo.toml", false, "1.9K", "Oct 11 22:40"), ("README.md", false, "6.1K", "Oct 10 14:03"),
            ("cmux-next-ios", true, "4.0K", "Oct 12 09:30"), ("docs", true, "4.0K", "Oct  8 11:15"),
            ("index.html", false, "3.2K", "Oct 12 08:55"), ("recordings", true, "4.0K", "Oct 12 09:02"),
            ("screenshots", true, "4.0K", "Oct 12 09:01"), ("scripts", true, "4.0K", "Oct  7 16:44"),
            ("src", true, "4.0K", "Oct 12 09:28"), ("target", true, "4.0K", "Oct 12 09:35"),
        ]
        guard long else {
            return [entries.map { $0.1 ? sgr("1;34", $0.0) : $0.0 }.joined(separator: "  ")]
        }
        var lines = ["total 512"]
        for (name, isDirectory, size, date) in entries {
            let mode = isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
            let shown = isDirectory ? sgr("1;34", name) : name
            lines.append("\(mode)  \(sgr("33", "aziz")) staff \(sgr("32", size.leftPad(5))) \(sgr("2", date)) \(shown)")
        }
        return lines
    }

    static let gitLog: [String] = {
        let commits = [
            ("4f98088", "cmux-next-ios: design specification", "HEAD -> main, origin/main"),
            ("c9676a2", "cmux-next-ios: app shell with native tabs and team sidebar", nil),
            ("3469bce", "cmux-next-ios: plan and v1 wire contract", nil),
            ("35e87a8", "Merge feat-imsg-integration into feat-cmux-next-ios", nil),
            ("d191aee", "nx-remote: SwiftPM and xcodebuild never use the keychain", nil),
            ("e580583", "nx-remote: tests for keychain-free package resolution", nil),
            ("7b69ed9", "build-fleet/data: fleet dump 2026/10/07", "tag: v0.81.0"),
            ("aa4c6c9", "nx-remote: cap Swift parallelism per job", nil),
            ("65770c4", "docs: standardize team secret retrieval", nil),
            ("1a2b3c4", "ghostty-next: restore READY cut at owner resize", nil),
            ("9e8d7c6", "link: WireGuard relay frames through TeamHub", nil),
            ("5f4e3d2", "hostd: splice daemon channel with allowlist", nil),
            ("0a9b8c7", "ffi: uniffi bindings for cmux-mobile-link", nil),
            ("6d5c4b3", "worker: TURN credentials from /v1/ice", nil),
            ("2e1f0a9", "terminal: mirror mode snapshots", nil),
            ("8b7a6c5", "feed: markdown cards with inline answers", nil),
            ("3c2b1a0", "design: tokens and glass chrome", nil),
            ("7f6e5d4", "Initial commit", nil),
        ]
        return commits.enumerated().map { index, commit in
            let graph = index == 3 ? sgr("31", "*") + sgr("32", "-.") : sgr("31", "*")
            let refs = commit.2.map { " " + sgr("33", "(") + sgr("1;36", $0) + sgr("33", ")") } ?? ""
            return "\(graph) \(sgr("33", commit.0))\(refs) \(commit.1)"
        }
    }()

    static let gitStatus: [String] = [
        "On branch \(sgr("35", "main"))",
        "Changes not staged for commit:",
        "  \(sgr("31", "modified:   cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal/TerminalScreen.swift"))",
        "  \(sgr("31", "modified:   docs/architecture.md"))",
        "Untracked files:",
        "  \(sgr("31", "screenshots/terminal.png"))",
    ]

    static let help: [String] = [
        "mock shell commands:",
        "  ls [-la]   git log   git status   cargo build   cat <file>",
        "  htop       vim <file>   clear   echo <text>",
    ]

    static func buildLog() -> [String] {
        let crates = [
            "proc-macro2 v1.0.92", "unicode-ident v1.0.14", "libc v0.2.169", "cfg-if v1.0.0", "once_cell v1.20.2",
            "serde v1.0.217", "quote v1.0.38", "syn v2.0.95", "memchr v2.7.4", "bytes v1.9.0", "pin-project-lite v0.2.16",
            "tokio-macros v2.5.0", "mio v1.0.3", "socket2 v0.5.8", "tokio v1.43.0", "tracing-core v0.1.33",
            "tracing v0.1.41", "futures-core v0.3.31", "futures-util v0.3.31", "smallvec v1.13.2", "itoa v1.0.14",
            "ryu v1.0.18", "serde_json v1.0.135", "thiserror v2.0.11", "anyhow v1.0.95", "ring v0.17.8",
            "rustls v0.23.21", "webpki-roots v0.26.7", "http v1.2.0", "httparse v1.9.5", "base64 v0.22.1",
            "sha2 v0.10.8", "rand_core v0.6.4", "rand v0.8.5", "x25519-dalek v2.0.1", "chacha20poly1305 v0.10.1",
            "boringtun v0.6.0", "smoltcp v0.12.0", "webrtc-util v0.9.0", "webrtc-dtls v0.10.0", "webrtc-sctp v0.10.0",
            "webrtc-data v0.10.0", "webrtc-ice v0.11.0", "webrtc v0.12.0", "uniffi_core v0.28.3", "uniffi v0.28.3",
            "cmux-mobile-proto v0.1.0 (/Users/aziz/cmux-next/cmux-next-ios/rust/cmux-mobile-proto)",
            "cmux-mobile-link v0.1.0 (/Users/aziz/cmux-next/cmux-next-ios/rust/cmux-mobile-link)",
            "cmux-mobile-host v0.1.0 (/Users/aziz/cmux-next/cmux-next-ios/rust/cmux-mobile-host)",
        ]
        var lines: [String] = [sgr("1;32", "    Updating") + " crates.io index"]
        var round = 0
        while lines.count < 360 {
            for crate in crates {
                let verb = round == 0 ? "   Compiling" : "    Checking"
                lines.append(sgr("1;32", verb) + " \(crate)")
                if lines.count % 37 == 0 {
                    lines.append(sgr("1;33", "warning") + sgr("1", ": unused variable: `frame`"))
                    lines.append("  \(sgr("1;34", "-->")) src/link/mux.rs:\(140 + lines.count % 30):9")
                    lines.append("   \(sgr("1;34", "|"))")
                    lines.append("\(sgr("1;34", "\(142 + lines.count % 30)")) \(sgr("1;34", "|")) let frame = Frame::decode(&mut buf)?;")
                    lines.append("   \(sgr("1;34", "|"))     \(sgr("1;33", "^^^^^")) help: prefix it with an underscore: `_frame`")
                    lines.append("   \(sgr("1;34", "="))  note: see https://doc.rust-lang.org/rustc/lints/listing/warn-by-default.html")
                }
                if lines.count >= 360 { break }
            }
            round += 1
        }
        lines.append(sgr("1;32", "    Finished") + " `release` profile [optimized] target(s) in 48.21s")
        lines.append("   Artifact target/release/cmux-mobile-host (8.4 MB)")
        lines.append("   Report   docs/architecture.md, index.html")
        lines.append("   Capture  screenshots/terminal.png, recordings/demo.mp4")
        lines.append("   Preview  http://localhost:5173/   PR https://github.com/manaflow-ai/cmux/pull/1234")
        return lines
    }

    static func fileLines(named name: String) -> [String] {
        if let text = MockArtifactSource.sampleText(for: name) {
            return text.components(separatedBy: "\n")
        }
        return ["# \(name)", "", "(empty mock file)"]
    }

    static func file(named name: String) -> [String] {
        MockArtifactSource.sampleText(for: name).map { $0.components(separatedBy: "\n") }
            ?? ["cat: \(name): No such file or directory"]
    }
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }

    func rightPad(_ width: Int) -> String {
        count >= width ? String(prefix(width)) : self + String(repeating: " ", count: width - count)
    }
}

/// htop's screen at a given tick, drawn for the grid (alternate screen).
struct MockHtop {
    static func render(columns: Int, rows: Int, tick: Int) -> String {
        let esc = "\u{1B}["
        var out = "\(esc)H"
        func line(_ row: Int, _ text: String) {
            out += "\(esc)\(row + 1);1H\(esc)2K" + text
        }
        let barWidth = max(10, columns / 2 - 9)
        func bar(_ label: String, _ value: Double) -> String {
            let filled = Int(Double(barWidth) * value)
            let green = min(filled, barWidth * 6 / 10)
            let red = filled - green
            let percent = String(format: "%4.1f%%", value * 100)
            return "\(esc)36m\(label)\(esc)0m\(esc)1m[\(esc)0m\(esc)32m" + String(repeating: "|", count: green)
                + "\(esc)31m" + String(repeating: "|", count: max(0, red)) + "\(esc)0m"
                + String(repeating: " ", count: max(0, barWidth - filled)) + "\(esc)2m\(percent)\(esc)0m\(esc)1m]\(esc)0m"
        }
        func load(_ core: Int) -> Double {
            let phase = Double(tick) * 0.7 + Double(core) * 1.3
            return min(0.98, max(0.03, 0.45 + 0.4 * sin(phase) * cos(phase * 0.37)))
        }
        for core in 0..<8 { line(core, bar(String(format: "%2d", core), load(core))) }
        line(8, bar("Mem", 0.62 + 0.02 * sin(Double(tick))) + " 14.9G/24.0G")
        line(9, bar("Swp", 0.08) + " 0.4G/4.0G")
        line(10, "\(esc)36mTasks:\(esc)0m \(esc)1m412\(esc)0m, 1873 thr; \(esc)32m3 running\(esc)0m  \(esc)36mLoad:\(esc)0m 3.2\(tick % 9) 2.87 2.41")
        line(11, "\(esc)36mUptime:\(esc)0m 4 days, 02:\(String(format: "%02d", 41 + tick / 60)):\(String(format: "%02d", tick % 60))")
        let header = "    PID USER      CPU% MEM%   TIME+  Command"
        line(13, "\(esc)30;42m" + header.rightPad(columns) + "\(esc)0m")
        let processes = ["cmux-next", "cmux-mobile-host", "ghostty-renderer", "claude", "codex", "cargo", "rustc", "node vite",
                         "WindowServer", "kernel_task", "Xcode", "simctl", "zsh", "tmux", "launchd", "mds_stores",
                         "Safari", "sshd", "ffmpeg", "python3", "git", "fseventsd", "coreaudiod", "bluetoothd",
                         "logd", "cfprefsd", "nsurlsessiond", "trustd", "UserEventAgent", "distnoted"]
        let listRows = max(0, rows - 15)
        for index in 0..<listRows {
            let name = processes[(index + tick / 3) % processes.count]
            let cpu = max(0, 38.0 / Double(index + 1) + Double((tick * 7 + index * 13) % 9) - 2)
            let row = String(format: "%7d %@ %5.1f %4.1f %3d:%02d.%02d  ", 4000 + index * 37, "aziz    ", cpu,
                             Double((index * 7) % 40) / 10, index, (tick + index) % 60, (index * 11) % 100)
            let selected = index == 0
            line(14 + index, (selected ? "\(esc)30;46m" : "") + (row + name).rightPad(columns) + "\(esc)0m")
        }
        let keys = [("F1", "Help"), ("F2", "Setup"), ("F3", "Search"), ("F5", "Tree"), ("F9", "Kill"), ("F10", "Quit")]
        let footer = keys.map { "\(esc)0m\($0.0)\(esc)30;46m\($0.1.rightPad(6))" }.joined()
        line(rows - 1, footer + "\(esc)0m")
        return out
    }
}

/// A small modal editor: normal mode with hjkl and arrows, insert mode, `:q`.
struct MockVim {
    enum Result { case stay, quit }
    enum Mode { case normal, insert, command(String) }

    let file: String
    var lines: [String]
    var row = 0
    var column = 0
    var top = 0
    var mode: Mode = .normal

    init(file: String, lines: [String]) {
        self.file = file
        self.lines = lines.isEmpty ? [""] : lines
    }

    mutating func handle(_ key: MockKey) -> Result {
        switch mode {
        case .command(let text):
            switch key {
            case .enter:
                mode = .normal
                if text.hasPrefix("q") || text.hasPrefix("wq") || text == "x" { return .quit }
            case .escape: mode = .normal
            case .backspace: mode = text.isEmpty ? .normal : .command(String(text.dropLast()))
            case .char(let character): mode = .command(text + String(character))
            default: break
            }
        case .insert:
            switch key {
            case .escape: mode = .normal; column = max(0, column - 1)
            case .enter:
                let current = lines[row]
                let index = current.index(current.startIndex, offsetBy: min(column, current.count))
                lines[row] = String(current[..<index])
                lines.insert(String(current[index...]), at: row + 1)
                row += 1; column = 0
            case .backspace:
                if column > 0 {
                    var characters = Array(lines[row]); characters.remove(at: column - 1)
                    lines[row] = String(characters); column -= 1
                }
            case .char(let character):
                var characters = Array(lines[row])
                characters.insert(character, at: min(column, characters.count))
                lines[row] = String(characters); column += 1
            default: move(key)
            }
        case .normal:
            switch key {
            case .char("i"): mode = .insert
            case .char("a"): mode = .insert; column = min(column + 1, lines[row].count)
            case .char("o"): lines.insert("", at: row + 1); row += 1; column = 0; mode = .insert
            case .char(":"): mode = .command("")
            case .char("x"):
                var characters = Array(lines[row])
                if column < characters.count { characters.remove(at: column); lines[row] = String(characters) }
            case .char("G"): row = lines.count - 1
            case .char("g"): row = 0
            case .char("0"): column = 0
            case .char("$"): column = max(0, lines[row].count - 1)
            default: move(key)
            }
        }
        return .stay
    }

    private mutating func move(_ key: MockKey) {
        switch key {
        case .left, .char("h"): column = max(0, column - 1)
        case .right, .char("l"): column = min(max(0, lines[row].count - 1), column + 1)
        case .up, .char("k"): row = max(0, row - 1)
        case .down, .char("j"): row = min(lines.count - 1, row + 1)
        default: return
        }
        column = min(column, max(0, lines[row].count - 1))
    }

    mutating func render(columns: Int, rows: Int) -> String {
        let esc = "\u{1B}["
        let textRows = max(1, rows - 2)
        if row < top { top = row }
        if row >= top + textRows { top = row - textRows + 1 }
        var out = "\(esc)?25l\(esc)H"
        for screenRow in 0..<textRows {
            out += "\(esc)\(screenRow + 1);1H\(esc)2K"
            let index = top + screenRow
            if index < lines.count {
                out += "\(esc)33m\(String(index + 1).leftPad(3))\(esc)0m " + highlight(String(lines[index].prefix(columns - 4)))
            } else {
                out += "\(esc)34m~\(esc)0m"
            }
        }
        let modeText: String = switch mode {
        case .insert: "\(esc)1m-- INSERT --\(esc)0m"
        case .command(let text): ":" + text
        case .normal: "\"\(file)\" \(lines.count)L"
        }
        let position = "\(row + 1),\(column + 1)"
        out += "\(esc)\(rows - 1);1H\(esc)2K\(esc)30;47m" + " \(file) [+]".rightPad(max(0, columns - position.count - 2)) + position + "  \(esc)0m"
        out += "\(esc)\(rows);1H\(esc)2K" + modeText
        if case .command(let text) = mode {
            out += "\(esc)\(rows);\(text.count + 2)H"
        } else {
            out += "\(esc)\(row - top + 1);\(column + 5)H"
        }
        out += "\(esc)?25h"
        return out
    }

    private func highlight(_ text: String) -> String {
        let esc = "\u{1B}["
        if text.hasPrefix("#") { return "\(esc)1;35m\(text)\(esc)0m" }
        if text.hasPrefix("```") || text.hasPrefix("    ") { return "\(esc)32m\(text)\(esc)0m" }
        if text.hasPrefix("- ") { return "\(esc)36m-\(esc)0m" + text.dropFirst() }
        return text
    }
}
#endif
