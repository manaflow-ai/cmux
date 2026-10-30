public import Foundation
import CmuxNextCompat

/// A small JSON state file beside the launch snapshot, written off the main thread (cmux#27749).
///
/// Leo (2026-10-29): "well somehow at "100% cpu" usage claude code desktop still seems fast / how
/// does that work? how can cmux next also do that? let's do that". Under agent disk load (git, rg,
/// compiles) a 64 KiB save as `Data.write(options: .atomic)` does it took 1.0 s at p95 on a fleet
/// mini, 44% of them over a frame (scripts/measure/qos-load-bench.sh), whatever priority the load
/// ran at. A save on the main thread, once per settled edit or scroll, is then a hang.
///
/// One serial utility queue per file keeps saves in call order; a save that a newer one replaced
/// before it ran is skipped, so a burst costs one write. The caller hands over a value, and the
/// encoding runs on the queue too; an encoding that throws leaves the file as the last save that
/// ran left it. ``read()`` waits for the saves already queued for the file, so a store made right
/// after a save reads it back. At quit ``flushAll(within:)`` waits, bounded, for queued saves, under the app's blocking
/// allowance. A crash or kill between a save's call and its write loses that save: the window is
/// the queue's backlog (a few milliseconds idle, up to a second under heavy disk load), the price
/// of never holding the main thread for the disk. The files hold a new chat's unsent text and
/// where each transcript was scrolled; the next settled edit or scroll saves again.
public nonisolated final class AgentPaneStateFile: Sendable {
    public let url: URL
    private let queue: DispatchQueue
    /// The newest save's number; a queued save with an older one does nothing.
    private let newest = Mutex<UInt64>(0)

    /// Set on this file's queue only, so a read from inside one of its saves does not wait on
    /// itself, and a read of another file from inside a save still waits for that file's saves.
    private let onQueue = DispatchSpecificKey<Bool>()

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
        queue.setSpecific(key: onQueue, value: true)
    }

    /// Saves what `encode` returns, atomically, on the file's queue; nil removes the file, and a
    /// throw keeps it as the last save that ran left it (a save this one replaced never ran).
    public func write(_ encode: @escaping @Sendable () throws -> Data?) {
        let number = newest.withLock { value in
            value += 1
            return value
        }
        queue.async { [self] in
            guard newest.withLock({ $0 == number }) else { return }
            let data: Data?
            do { data = try encode() } catch { return }  // a throw keeps the last good file
            guard let data else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The file's bytes once the saves queued before this call have run; nil when there is none.
    public func read() -> Data? {
        if DispatchQueue.getSpecific(key: onQueue) == true { return try? Data(contentsOf: url) }
        // concurrency-allow: one small local read per store (at its first use), after this file's queued saves
        return queue.sync { try? Data(contentsOf: url) }
    }

    /// Waits up to `limit` in all for every file's queued saves. App quit only (inside
    /// `allowBlocking(.terminate)`); false when some were still queued at the deadline.
    @discardableResult
    public static func flushAll(within limit: TimeInterval = 2) -> Bool {
        let all = files.withLock { Array($0.values) }
        // concurrency-allow: app quit only, inside allowBlocking(.terminate); bounded by `limit` for all files together
        let drained = DispatchSemaphore(value: 0)
        for file in all { file.queue.async { drained.signal() } }
        let deadline = DispatchTime.now() + limit
        for _ in all {
            // concurrency-allow: app quit only; one shared deadline for every file
            if drained.wait(timeout: deadline) == .timedOut { return false }
        }
        return true
    }
}
