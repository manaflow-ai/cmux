import AppKit
import Testing
@testable import CmuxNextTerminal

/// SCRATCH (-nomerge): CPU load while TerminalSurfaceCommitSizeTests runs, to test whether a starved Ghostty renderer
/// thread is the cause of its red runs. `threads` busy threads at the main thread's QoS; 0 runs without load.
nonisolated final class RenderLoad: @unchecked Sendable {
    static let threads = 0
    static let shared = RenderLoad()
    private let lock = NSLock()
    private var on = false

    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return on
    }

    func start() {
        lock.lock()
        on = Self.threads > 0
        lock.unlock()
        for _ in 0..<Self.threads {
            let thread = Thread { [self] in
                var x: UInt64 = 1
                while running {
                    for _ in 0..<100_000 { x = x &* 6364136223846793005 &+ 1442695040888963407 }
                }
                if x == 42 { print("") }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    func stop() {
        lock.lock()
        on = false
        lock.unlock()
    }
}

@MainActor
enum CommitSizeTrace {
    static func begin(_ window: NSWindow) {
        let presenter = TerminalFramePresenter.forWindow(window)
        presenter.trace = []
        RenderLoad.shared.start()
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        presenter.note("begin load-threads=\(RenderLoad.threads) cpus=\(ProcessInfo.processInfo.activeProcessorCount) loadavg=\(load.map { String(format: "%.2f", $0) }.joined(separator: ","))")
    }

    static func end(_ window: NSWindow) {
        let presenter = TerminalFramePresenter.forWindow(window)
        RenderLoad.shared.stop()
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        presenter.note("end loadavg=\(load.map { String(format: "%.2f", $0) }.joined(separator: ",")) stats=\(presenter.stats)")
        let name = Test.current?.name ?? "?"
        let lines = presenter.trace ?? []
        presenter.trace = nil
        print("TRACE-BEGIN \(name) (\(lines.count) lines)\n" + lines.map { "TRACE \(name) \($0)" }.joined(separator: "\n") + "\nTRACE-END \(name)")
    }
}
