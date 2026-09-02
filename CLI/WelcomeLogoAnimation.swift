import Darwin
import Foundation

/// Renders the seven-row `::` cmux logo for one frame of the welcome ripple.
///
/// Pure: no I/O, so tests can assert exact frame bytes. Frame 0 is the canonical
/// static gradient. During the animation a pulse travels left to right across
/// the diamond; every `::` pair it passes is shifted along a ping-pong palette
/// (cyan → purple → cyan) by an amount that peaks at the pulse center, so the
/// colors ripple horizontally and settle back to the canonical gradient once
/// the pulse has left the logo.
struct WelcomeLogoFrameRenderer {
    struct RGB: Equatable {
        let red: Int
        let green: Int
        let blue: Int

        var sgr: String { "\u{001B}[38;2;\(red);\(green);\(blue)m" }
    }

    static let rowCount = 7

    /// Top-to-bottom gradient of the static logo.
    static let gradient: [RGB] = [
        RGB(red: 0, green: 212, blue: 255),
        RGB(red: 24, green: 181, blue: 250),
        RGB(red: 48, green: 150, blue: 245),
        RGB(red: 72, green: 119, blue: 241),
        RGB(red: 96, green: 88, blue: 239),
        RGB(red: 110, green: 73, blue: 238),
        RGB(red: 124, green: 58, blue: 237),
    ]

    /// Gradient followed by its interior reversed, so shifting along the cycle
    /// goes cyan → purple → cyan without a hard jump at the wrap.
    static let pingPongPalette: [RGB] = gradient + gradient.dropFirst().dropLast().reversed()

    static var cycleLength: Int { pingPongPalette.count }

    static let reset = "\u{001B}[0m"

    /// Leading spaces and number of `::` pairs on each row.
    static let rowShapes: [(indent: Int, pairs: Int)] = [
        (2, 1), (4, 2), (6, 3), (8, 3), (6, 3), (4, 2), (2, 1),
    ]

    /// The `::` glyph block for each row, without color codes.
    static let glyphs: [String] = rowShapes.map {
        String(repeating: " ", count: $0.indent) + String(repeating: "::", count: $0.pairs)
    }

    /// Horizontal position of a pair, in pair units (two columns each).
    static func pairColumn(row: Int, pair: Int) -> Int {
        rowShapes[row].indent / 2 + pair
    }

    /// Half-width of the pulse in pair units, and the maximum palette shift at
    /// its center.
    static let pulseWidth = 6

    /// Pair columns the pulse advances per frame.
    static let pulseSpeed = 0.5

    /// Frames until the pulse has left the widest row on the right. Frame 0 and
    /// every frame from `frameCount` on render the canonical gradient.
    static var frameCount: Int {
        let lastColumn = rowShapes.map { $0.indent / 2 + $0.pairs - 1 }.max() ?? 0
        // Pulse center starts at -pulseWidth (fully left of column 0) and must
        // reach lastColumn + pulseWidth.
        return Int((Double(lastColumn + 2 * pulseWidth) / pulseSpeed).rounded(.up))
    }

    /// Pulse center in pair units at `frameIndex`.
    static func pulseCenter(frameIndex: Int) -> Double {
        Double(frameIndex) * pulseSpeed - Double(pulseWidth)
    }

    /// Palette steps a pair at `pairColumn` is shifted by at `frameIndex`.
    static func paletteShift(pairColumn: Int, frameIndex: Int) -> Int {
        let distance = abs(Double(pairColumn) - pulseCenter(frameIndex: frameIndex))
        return max(0, Int((Double(pulseWidth) - distance).rounded()))
    }

    /// Color of one `::` pair at `frameIndex`.
    static func color(row: Int, pair: Int, frameIndex: Int) -> RGB {
        let shift = paletteShift(pairColumn: pairColumn(row: row, pair: pair), frameIndex: frameIndex)
        return pingPongPalette[(row + shift) % cycleLength]
    }

    /// SGR prefix for the tagline text to the right of the logo.
    let taglineColor: String

    /// Static text that follows the glyph block on each row. It keeps its own
    /// colors so only the `::` block animates.
    func trailer(row: Int) -> String {
        let g = Self.gradient
        switch row {
        case 1:
            return "              \(g[0].sgr)c\(g[1].sgr)m\(g[2].sgr)u\(g[6].sgr)x\(Self.reset)"
        case 3:
            return "        \(taglineColor)the open source terminal\(Self.reset)"
        case 4:
            return "          \(taglineColor)built for coding agents\(Self.reset)"
        default:
            return ""
        }
    }

    /// One logo row with SGR codes and no trailing newline. Adjacent pairs with
    /// the same color share one SGR prefix, so frame 0 is byte-identical to the
    /// original static logo.
    func row(_ row: Int, frameIndex: Int) -> String {
        let shape = Self.rowShapes[row]
        var out = ""
        var current: RGB?
        for pair in 0..<shape.pairs {
            let color = Self.color(row: row, pair: pair, frameIndex: frameIndex)
            if color != current {
                out += color.sgr
                if pair == 0 {
                    // The SGR precedes the indent, matching the original static logo bytes.
                    out += String(repeating: " ", count: shape.indent)
                }
                current = color
            }
            out += "::"
        }
        return out + Self.reset + trailer(row: row)
    }

    /// All `rowCount` rows for `frameIndex`.
    func rows(frameIndex: Int) -> [String] {
        (0..<Self.rowCount).map { row($0, frameIndex: frameIndex) }
    }
}

/// Repaints the logo in place after the welcome screen has been printed.
///
/// Two modes. Detached: `cmux welcome` queries the cursor row, spawns
/// `cmux __welcome-animate <topRow>` in its own session, and exits so the
/// shell prompt appears immediately while the helper repaints absolute rows
/// above it. In-process fallback: a render thread repaints rows relative to
/// the cursor while the main thread waits on a bounded deadline.
final class WelcomeLogoAnimator {
    enum Placement: Equatable {
        /// Rows between the logo's first row and the cursor row, exclusive of
        /// the cursor row. Only valid while this process owns the cursor.
        case relative(linesAboveCursor: Int)
        /// One-based terminal row of the logo's first row. Survives the shell
        /// printing its prompt below, but not scrolling.
        case absolute(topRow: Int)
    }

    struct Configuration: Equatable {
        /// Number of animated frames after the static frame 0.
        var frameCount: Int = WelcomeLogoFrameRenderer.frameCount - 1
        var frameInterval: TimeInterval = 0.03
        var placement: Placement

        var duration: TimeInterval { Double(frameCount) * frameInterval }
    }

    /// Thread-safe cancellation flag shared between the main thread and the
    /// render thread.
    final class CancellationToken {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    /// Handle for a running background animation.
    final class Handle {
        private let done = DispatchSemaphore(value: 0)
        private let token: CancellationToken

        fileprivate init(token: CancellationToken) {
            self.token = token
        }

        fileprivate func finish() {
            done.signal()
        }

        func cancel() {
            token.cancel()
        }

        /// Waits up to `timeout` for the render thread to finish. Returns
        /// `true` when it finished in time.
        @discardableResult
        func wait(timeout: TimeInterval) -> Bool {
            done.wait(timeout: .now() + timeout) == .success
        }
    }

    let renderer: WelcomeLogoFrameRenderer
    let configuration: Configuration

    init(renderer: WelcomeLogoFrameRenderer, configuration: Configuration) {
        self.renderer = renderer
        self.configuration = configuration
    }

    /// Whether any in-place repaint is safe and wanted.
    ///
    /// - `isTTY`: stdout is a terminal. Pipes and files get the static frame only.
    /// - `terminalRows`: rows reported by `TIOCGWINSZ`, or nil when unknown. The
    ///   whole welcome must fit so the logo's first row is still on screen.
    /// - Environment: `TERM=dumb`, `NO_COLOR`, `CI`, or `CMUX_WELCOME_ANIMATE=0`
    ///   disable the animation.
    static func shouldAnimate(
        environment: [String: String],
        isTTY: Bool,
        terminalRows: Int?,
        linesAboveCursor: Int
    ) -> Bool {
        guard isTTY else { return false }
        guard let rows = terminalRows, rows >= linesAboveCursor + 1 else { return false }
        if environment["CMUX_WELCOME_ANIMATE"] == "0" { return false }
        if let noColor = environment["NO_COLOR"], !noColor.isEmpty { return false }
        if let ci = environment["CI"], !ci.isEmpty { return false }
        guard let term = environment["TERM"], !term.isEmpty, term != "dumb" else { return false }
        return true
    }

    /// Rows the cursor may still move down (prompt newlines) before the screen
    /// scrolls and absolute rows go stale.
    static let detachedScrollMargin = 2

    /// Absolute placement for a detached helper, or nil when the logo could
    /// scroll off before the ripple ends. `cursorRow` is the one-based row the
    /// shell prompt will be printed on.
    static func detachedPlacement(cursorRow: Int, linesAboveCursor: Int, terminalRows: Int) -> Placement? {
        let topRow = cursorRow - linesAboveCursor
        guard topRow >= 1 else { return nil }
        guard cursorRow + detachedScrollMargin <= terminalRows else { return nil }
        return .absolute(topRow: topRow)
    }

    /// One complete in-place repaint. Every row is positioned from the saved
    /// cursor (relative) or by absolute row, so the sequence is self-contained:
    /// emit it in a single `write` and the terminal is consistent between
    /// frames no matter when the process exits.
    static func repaintSequence(rows: [String], placement: Placement) -> String {
        var out = "\u{001B}7"
        for (index, row) in rows.enumerated() {
            switch placement {
            case .relative(let linesAboveCursor):
                let up = linesAboveCursor - index
                out += "\u{001B}8"
                if up > 0 {
                    out += "\u{001B}[\(up)A"
                }
                out += "\r"
            case .absolute(let topRow):
                out += "\u{001B}[\(topRow + index);1H"
            }
            out += "\u{001B}[2K"
            out += row
        }
        out += "\u{001B}8"
        return out
    }

    /// Synchronous render loop. `write` receives one complete repaint per call
    /// and returns `false` to stop (for example on `EPIPE`). `sleep` paces
    /// frames. The loop always ends by writing the canonical frame unless the
    /// writer has already failed, so a cancelled animation still leaves the
    /// static logo on screen.
    func renderLoop(
        write: (String) -> Bool,
        sleep: (TimeInterval) -> Void,
        isCancelled: () -> Bool
    ) {
        var writerAlive = true
        for frame in 1...max(configuration.frameCount, 1) {
            if isCancelled() { break }
            sleep(configuration.frameInterval)
            if isCancelled() { break }
            let rows = renderer.rows(frameIndex: frame)
            let sequence = Self.repaintSequence(rows: rows, placement: configuration.placement)
            guard write(sequence) else {
                writerAlive = false
                break
            }
        }
        guard writerAlive else { return }
        let finalRows = renderer.rows(frameIndex: 0)
        _ = write(Self.repaintSequence(rows: finalRows, placement: configuration.placement))
    }

    /// Starts the render loop on a background thread and returns immediately.
    func start(
        write: @escaping (String) -> Bool,
        sleep: @escaping (TimeInterval) -> Void
    ) -> Handle {
        let token = CancellationToken()
        let handle = Handle(token: token)
        let thread = Thread { [self] in
            self.renderLoop(write: write, sleep: sleep, isCancelled: { token.isCancelled })
            handle.finish()
        }
        thread.name = "cmux.welcome.logo-animation"
        thread.qualityOfService = .userInteractive
        thread.start()
        return handle
    }

    /// Writes all of `text` to `fd`, retrying on `EINTR`/`EAGAIN`. Returns
    /// `false` on any other error.
    static func writeAll(fd: Int32, _ text: String) -> Bool {
        let data = Array(text.utf8)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBufferPointer { buffer -> Int in
                Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && (errno == EINTR || errno == EAGAIN) {
                continue
            }
            return false
        }
        return true
    }

    /// Runs the animation on stdout from a background thread and blocks the
    /// caller until it finishes or the deadline passes. On a slow terminal the
    /// loop is cancelled; the render thread then paints the canonical frame
    /// and exits.
    func runOnStdout() {
        let handle = start(
            write: { Self.writeAll(fd: STDOUT_FILENO, $0) },
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
        let grace: TimeInterval = 1.0
        if !handle.wait(timeout: configuration.duration + grace) {
            handle.cancel()
            handle.wait(timeout: grace)
        }
    }

    // MARK: - Cursor position report

    /// Parses a `CSI row ; col R` cursor position report anywhere in `bytes`.
    /// Returns the one-based row, or nil when no complete report is present.
    static func parseCursorReportRow(_ bytes: [UInt8]) -> Int? {
        var index = 0
        while index + 1 < bytes.count {
            guard bytes[index] == 0x1B, bytes[index + 1] == UInt8(ascii: "[") else {
                index += 1
                continue
            }
            var cursor = index + 2
            var row = 0
            var digits = 0
            while cursor < bytes.count, bytes[cursor] >= UInt8(ascii: "0"), bytes[cursor] <= UInt8(ascii: "9") {
                row = row * 10 + Int(bytes[cursor] - UInt8(ascii: "0"))
                digits += 1
                cursor += 1
            }
            guard digits > 0, cursor < bytes.count, bytes[cursor] == UInt8(ascii: ";") else {
                index += 1
                continue
            }
            cursor += 1
            var colDigits = 0
            while cursor < bytes.count, bytes[cursor] >= UInt8(ascii: "0"), bytes[cursor] <= UInt8(ascii: "9") {
                colDigits += 1
                cursor += 1
            }
            guard colDigits > 0, cursor < bytes.count else {
                // Incomplete report so far.
                return nil
            }
            if bytes[cursor] == UInt8(ascii: "R") {
                return row
            }
            index += 1
        }
        return nil
    }

    /// Asks the terminal where the cursor is (`DSR 6`) and returns the one-based
    /// row, or nil when stdin/stdout are not the same interactive terminal or
    /// the reply does not arrive within `timeout`. Puts stdin in raw mode for
    /// the duration so the reply is not echoed or line-buffered.
    static func queryCursorRow(
        inputFD: Int32 = STDIN_FILENO,
        outputFD: Int32 = STDOUT_FILENO,
        timeout: TimeInterval = 0.25
    ) -> Int? {
        guard isatty(inputFD) == 1, isatty(outputFD) == 1 else { return nil }
        var original = termios()
        guard tcgetattr(inputFD, &original) == 0 else { return nil }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(inputFD, TCSANOW, &raw) == 0 else { return nil }
        defer { _ = tcsetattr(inputFD, TCSANOW, &original) }

        guard writeAll(fd: outputFD, "\u{001B}[6n") else { return nil }

        var buffer: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.count < 64 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32((remaining * 1000).rounded(.up)))
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { return nil }
            var byte: UInt8 = 0
            let count = Darwin.read(inputFD, &byte, 1)
            guard count == 1 else { return nil }
            buffer.append(byte)
            if let row = parseCursorReportRow(buffer) {
                return row
            }
        }
        return nil
    }

    // MARK: - Detached helper

    static let detachedCommand = "__welcome-animate"

    /// Spawns `<executable> __welcome-animate <topRow>` in its own session with
    /// stdin and stderr on /dev/null and stdout inherited, so it keeps painting
    /// the terminal after this process exits and the shell shows its prompt.
    static func spawnDetached(executablePath: String, topRow: Int) -> Bool {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for fd in [STDIN_FILENO, STDERR_FILENO] {
            let status = "/dev/null".withCString { path in
                posix_spawn_file_actions_addopen(&fileActions, fd, path, fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
            }
            guard status == 0 else { return false }
        }
        guard posix_spawn_file_actions_addinherit_np(&fileActions, STDOUT_FILENO) == 0 else { return false }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            return false
        }

        let environmentStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let arguments: [String] = [executablePath, detachedCommand, String(topRow)]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        var envp: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
        defer {
            for item in argv { free(item) }
            for item in envp { free(item) }
        }
        argv.append(nil)
        envp.append(nil)
        var pid: pid_t = 0
        return posix_spawn(&pid, executablePath, &fileActions, &attributes, &argv, &envp) == 0
    }
}
