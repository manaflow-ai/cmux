public import Foundation
import CmuxNextCompat

/// A small JSON state file beside the launch snapshot, written off the main thread (cmux#27587 follow-up).
///
/// Leo (2026-10-29): "well somehow at "100% cpu" usage claude code desktop still seems fast / how
/// does that work? how can cmux next also do that? let's do that". Under agent disk load (git, rg,
/// compiles) a 64 KiB save as `Data.write(options: .atomic)` does it took 1.0 s at p95 on a fleet
/// mini, 44% of them over a frame (scripts/measure/qos-load-bench.sh), whatever priority the load
/// ran at. A save on the main thread, once per settled edit or scroll, is then a hang.
///
/// One serial utility queue per file keeps writes in call order; a write that a newer one replaced
/// before it ran is skipped, so a burst costs one write. The caller hands over a value, and the
/// encoding runs on the queue too. ``read()`` waits for the writes already queued for the file, so
/// a store made right after a write reads it back (a relaunch reads a file the last run finished).
/// At quit ``flushAll(within:)`` waits for queued writes, under the app's blocking allowance.
public nonisolated final class AgentPaneStateFile: Sendable {
    public let url: URL
    private let queue: DispatchQueue
    /// The newest write's number; a queued write with an older one does nothing.
    private let newest = Mutex<UInt64>(0)

    private static let files = Mutex<[String: AgentPaneStateFile]>([:])

    /// The one writer for `url`: two stores of one file (a test's fresh store, a second window)
    /// share its queue and so its order.
    public static func at(_ url: URL) -> AgentPaneStateFile {
        files.withLock { files in
            let key = url.standardizedFileURL.path
            if let file = files[key] { return file }
            let file = AgentPaneStateFile(url: url)
            files[key] = file
            return file
        }
    }

    private init(url: URL) {
        self.url = url
        queue = DispatchQueue(label: "com.cmuxterm.app.next.agent-pane.state-file", qos: .utility)
    }

    /// Writes what `encode` returns, atomically, on the file's queue; nil removes the file.
    public func write(_ encode: @escaping @Sendable () -> Data?) {
        let number = newest.withLock { value in
            value += 1
            return value
        }
        queue.async { [self] in
            guard newest.withLock({ $0 == number }) else { return }
            if let data = encode() {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// The file's bytes once the writes queued before this call have run; nil when there is none.
    public func read() -> Data? {
        // concurrency-allow: one small local read per store (at its first use), after this file's queued writes
        queue.sync { try? Data(contentsOf: url) }
    }

    /// Waits for every file's queued writes. App quit only (inside `allowBlocking(.terminate)`).
    public static func flushAll(within limit: TimeInterval = 2) {
        let all = files.withLock { Array($0.values) }
        let deadline = Date().addingTimeInterval(limit)
        for file in all where Date() < deadline {
            // concurrency-allow: app quit only; each queue holds at most one pending small write
            file.queue.sync {}
        }
    }
}
