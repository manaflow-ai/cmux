import CmuxNextCompat
import Darwin
import Foundation

/// Claude Code's `claude setup-token`, run with no terminal tab: the token it prints is read from
/// its output and saved like a pasted one, so there is nothing to copy (Leo, 2026-11-25: "surely we
/// can minimize the cruft all around here").
///
/// The CLI draws with Ink and prints nothing without a terminal, so it runs on a pseudo-terminal
/// that is 4096 columns wide: the long token stays on one line instead of being wrapped and padded.
/// It opens the person's browser itself; once they approve, it prints the token. Only the token is
/// kept, never the rest of the output, and the CLI is stopped as soon as the token has been read.
/// The paste field stays for a CLI that asks for a code instead.
nonisolated enum ClaudeSetupTokenCapture {
    /// How long the person has to approve in the browser.
    static let timeout: Duration = .seconds(600)
    /// The most output read before giving up.
    static let outputCap = 256 * 1024
    static let columns: UInt16 = 4096
    static let prefix = "sk-ant-oat"
    /// The kill switch: `defaults write com.cmuxterm.app.next cmuxNext.claudeSetupTokenCapture.off -bool YES`
    /// (or the app's own domain) hides Sign In and leaves the paste field, as before this ran in the app.
    static let killSwitch = "cmuxNext.claudeSetupTokenCapture.off"

    /// Whether Sign In runs `claude setup-token` in the app: on unless the kill switch is set.
    static func enabled(_ defaults: UserDefaults = .standard) -> Bool { !defaults.bool(forKey: killSwitch) }

    enum Failure: Error, Equatable {
        /// No pseudo-terminal could be opened or the CLI could not be started.
        case noTerminal
        /// The CLI ended, timed out or was cancelled without printing a token.
        case noToken
    }

    /// The last setup token in OUTPUT, with terminal escapes taken out. While OUTPUT may still grow
    /// (`ended` false), a token must be followed by something, so a half-written one is not taken.
    static func token(in output: Data, ended: Bool = true) -> String? {
        let text = Array(plain(String(decoding: output, as: UTF8.self)).utf8)
        let marker = Array(prefix.utf8)
        var found: String?
        var index = 0
        while index + marker.count <= text.count {
            guard Array(text[index..<index + marker.count]) == marker else {
                index += 1
                continue
            }
            var end = index + marker.count
            while end < text.count, isTokenByte(text[end]) { end += 1 }
            if end - index > marker.count + 8, ended || end < text.count {
                found = String(decoding: text[index..<end], as: UTF8.self)
            }
            index = end
        }
        return found
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"): true
        default: false
        }
    }

    /// TEXT without terminal escapes: a color change is dropped (it may sit inside a word), any other
    /// control sequence (a cursor move Ink uses for a space) becomes a space, and an OSC (a link) or
    /// DCS string is dropped up to its terminator.
    static func plain(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            guard scalar == "\u{1B}" || scalar == "\u{9B}" else {
                out.append(scalar)
                continue
            }
            let introducer: Unicode.Scalar = scalar == "\u{9B}" ? "[" : (index < scalars.count ? scalars[index] : " ")
            if scalar == "\u{1B}" { index += 1 }
            switch introducer {
            case "[":
                // Parameters and intermediates, then one final byte.
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) { index += 1 }
                let last = index < scalars.count ? scalars[index] : "m"
                index += 1
                if last != "m" { out.append(" ") }
            case "]", "P", "_", "^", "X":
                // Up to BEL or ESC \.
                while index < scalars.count {
                    if scalars[index] == "\u{07}" {
                        index += 1
                        break
                    }
                    if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                // A two-byte escape: the byte after ESC was its whole body.
                break
            }
        }
        return String(out)
    }

    /// Where Claude Code's installers put `claude`, for when acpmux's health check has not named it.
    static func installed(home: String = NSHomeDirectory(),
                          exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first(where: exists)
    }

    /// The running CLI, stopped once from whichever of the timeout, a cancel or the end gets there first.
    private final class Running: Sendable {
        private let held: Mutex<Process?>
        init(_ process: consuming sending Process) { held = Mutex(process) }

        func stop() {
            guard let process = held.withLock({ $0.take() }) else { return }
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs `<claude> setup-token` on a pseudo-terminal and answers the token it prints.
    @concurrent static func run(claude: String) async throws -> String {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &size) == 0 else { throw Failure.noTerminal }
        defer { close(primary) }
        let terminal = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["setup-token"]
        var environment = ProcessInfo.processInfo.environment
        if (environment["TERM"] ?? "").isEmpty || environment["TERM"] == "dumb" { environment["TERM"] = "xterm-256color" }
        // An app's PATH is short; a `claude` that is a node script finds node beside it or in Homebrew.
        let folder = URL(fileURLWithPath: claude).deletingLastPathComponent().path
        environment["PATH"] = ([folder, "/opt/homebrew/bin", "/usr/local/bin"] + [environment["PATH"] ?? "/usr/bin:/bin"])
            .joined(separator: ":")
        process.environment = environment
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        do { try process.run() } catch { throw Failure.noTerminal }
        // Only the CLI holds the terminal now, so the read below ends when it exits.
        try? terminal.close()

        let running = Running(process)
        let timer = Task {
            // concurrency-allow: a deadline off the main thread (run is @concurrent), cancelled when the CLI ends
            try? await Task.sleep(for: timeout)
            running.stop()
        }
        let reader = primary
        let output: Data = await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Data, Never>) in
                Thread.detachNewThread {
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while data.count < outputCap {
                        let count = read(reader, &buffer, buffer.count)
                        if count > 0 {
                            data.append(contentsOf: buffer[0..<count])
                            if token(in: data, ended: false) != nil { break }
                        } else if count < 0, errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                    done.resume(returning: data)
                }
            }
        } onCancel: {
            running.stop()
        }
        timer.cancel()
        running.stop()
        guard let token = token(in: output) else { throw Failure.noToken }
        return token
    }
}
