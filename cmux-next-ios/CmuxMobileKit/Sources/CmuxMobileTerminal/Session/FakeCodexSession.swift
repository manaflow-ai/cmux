// DEBUG and Demo builds only: never compiled into Production.
#if DEBUG
import Foundation

/// A Codex CLI-like inline TUI for reproducing terminal behavior without a
/// Mac (`-cmux-mobile-term-fake-codex`, mock mode). It mirrors a remote screen like
/// the Mac's sessions do (`remoteRows`), keeps a live area at the bottom
/// (input box with the cursor, a status row below it) and streams numbered
/// history lines above it the way Codex does: a scroll region from the
/// screen's top, a line feed per line, then the live area redrawn.
@MainActor
public final class FakeCodexSession: TerminalSession {
    public let programName = "codex"
    public var isAlternateScreen: Bool { false }
    public private(set) var remoteRows: Int? = 37
    private var columns = 53
    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
    private var task: Task<Void, Never>?
    private var line = 0
    /// Lines per second.
    private let rate: Double

    /// Working, not streaming: a long transcript, then only the status line
    /// redrawn every second the way Codex does it: the cursor goes up to the
    /// live area, clears to the end of the screen, and the rows come back in
    /// a later write (user report 2026-10-14, "blinking and oscillating").
    private let idleRedraw: Bool

    public init(rate: Double = 14, idleRedraw: Bool = false) {
        self.rate = rate
        self.idleRedraw = idleRedraw
    }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        self.handler = handler
        handler(.connection(.attached))
        emit("\u{1B}c\u{1B}[H\u{1B}[2J")
        for index in 1...6 { emit("shell line \(index)\r\n") }
        emit("> codex\r\n")
        drawLive(timer: 0)
        if idleRedraw {
            for index in 1...300 { insertHistory("transcript line \(index)") }
            drawLive(timer: 0)
            task = Task { @MainActor [weak self] in
                var tick = 0
                while let self, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    tick += 1
                    let liveTop = self.rows - 4
                    // Clear the live area in one write...
                    self.emit("\u{1B}[?25l\u{1B}[\(liveTop);1H\u{1B}[J")
                    // ...and draw it again in the next one.
                    try? await Task.sleep(for: .milliseconds(30))
                    self.drawLive(timer: tick)
                    self.emit("\u{1B}[?25h")
                }
            }
            return
        }
        task = Task { @MainActor [weak self] in
            var tick = 0
            // A pause first, then a long reply streams in.
            try? await Task.sleep(for: .seconds(3))
            while let self, !Task.isCancelled, self.line < 400 {
                self.line += 1
                tick += 1
                self.insertHistory("reply line \(self.line)")
                self.drawLive(timer: tick)
                try? await Task.sleep(for: .milliseconds(Int(1000 / self.rate)))
            }
        }
    }

    private var rows: Int { remoteRows ?? 37 }

    /// Codex's history insert: region 1..(top of the live area), cursor to
    /// its last row, CR LF + the line, region reset.
    private func insertHistory(_ text: String) {
        let liveTop = rows - 4
        emit("\u{1B}[1;\(liveTop - 1)r\u{1B}[\(liveTop - 1);1H\r\n\(text)\u{1B}[r")
    }

    /// The live area: a rule, the input box (cursor there) and a status row below it.
    private func drawLive(timer: Int) {
        let liveTop = rows - 4
        emit("\u{1B}[\(liveTop);1H\u{1B}[2K" + String(repeating: "─", count: min(columns, 40)))
        emit("\u{1B}[\(liveTop + 1);1H\u{1B}[2K› ")
        emit("\u{1B}[\(liveTop + 3);1H\u{1B}[2KWorking (\(timer)s) · esc to interrupt")
        emit("\u{1B}[\(liveTop + 1);3H")
    }

    private func emit(_ text: String) {
        handler?(.output(Data(text.utf8)))
    }

    public func send(_ bytes: Data) {}

    public func resize(columns: Int, rows: Int) {
        self.columns = columns
        remoteRows = rows
    }

    public func stop() {
        task?.cancel()
        handler = nil
    }
}
#endif
