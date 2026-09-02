import Darwin
import Foundation

/// Renders the seven-row `::` cmux logo for one frame of the welcome color wave.
///
/// Pure: no I/O, so tests can assert exact frame bytes. Frame 0 is the canonical
/// static gradient; frames cycle through an extended ping-pong palette so the
/// wave has no visible seam and returns to the canonical gradient every
/// `cycleLength` frames.
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

    /// Gradient followed by its interior reversed, so walking the cycle goes
    /// cyan → purple → cyan without a hard jump at the wrap.
    static let pingPongPalette: [RGB] = gradient + gradient.dropFirst().dropLast().reversed()

    static var cycleLength: Int { pingPongPalette.count }

    static let reset = "\u{001B}[0m"

    /// SGR prefix for the tagline text to the right of the logo.
    let taglineColor: String

    /// Color of `row` at `frameIndex`. Colors flow upward one row per frame.
    static func color(row: Int, frameIndex: Int) -> RGB {
        let palette = pingPongPalette
        let count = palette.count
        let index = ((row + frameIndex) % count + count) % count
        return palette[index]
    }

    /// The `::` glyph block for each row, without color codes.
    static let glyphs: [String] = [
        "  ::",
        "    ::::",
        "      ::::::",
        "        ::::::",
        "      ::::::",
        "    ::::",
        "  ::",
    ]

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

    /// One logo row with SGR codes and no trailing newline.
    func row(_ row: Int, frameIndex: Int) -> String {
        let color = Self.color(row: row, frameIndex: frameIndex)
        return "\(color.sgr)\(Self.glyphs[row])\(Self.reset)\(trailer(row: row))"
    }

    /// All `rowCount` rows for `frameIndex`.
    func rows(frameIndex: Int) -> [String] {
        (0..<Self.rowCount).map { row($0, frameIndex: frameIndex) }
    }
}

/// Repaints the logo in place from a background thread after the welcome
/// screen has been printed. The main thread owns the lifecycle: it starts the
/// animator, waits with a bounded deadline, and cancels if the terminal is slow.
final class WelcomeLogoAnimator {
    struct Configuration: Equatable {
        /// Number of animated frames after the static frame 0. A multiple of
        /// `WelcomeLogoFrameRenderer.cycleLength` ends on the canonical gradient.
        var frameCount: Int = 2 * WelcomeLogoFrameRenderer.cycleLength
        var frameInterval: TimeInterval = 0.05
        /// Rows between the logo's first row and the cursor row, exclusive of
        /// the cursor row. The cursor must sit on a line below the logo.
        var linesAboveCursor: Int

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

    /// Decides whether the in-place repaint is safe and wanted.
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

    /// One complete in-place repaint. Every row is positioned from the saved
    /// cursor so the sequence is self-contained: emit it in a single `write`
    /// and the terminal is consistent between frames no matter when the
    /// process exits.
    static func repaintSequence(rows: [String], linesAboveCursor: Int) -> String {
        var out = "\u{001B}7"
        for (index, row) in rows.enumerated() {
            let up = linesAboveCursor - index
            out += "\u{001B}8"
            if up > 0 {
                out += "\u{001B}[\(up)A"
            }
            out += "\r\u{001B}[2K"
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
            let sequence = Self.repaintSequence(rows: rows, linesAboveCursor: configuration.linesAboveCursor)
            guard write(sequence) else {
                writerAlive = false
                break
            }
        }
        guard writerAlive else { return }
        let finalRows = renderer.rows(frameIndex: 0)
        _ = write(Self.repaintSequence(rows: finalRows, linesAboveCursor: configuration.linesAboveCursor))
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
}
