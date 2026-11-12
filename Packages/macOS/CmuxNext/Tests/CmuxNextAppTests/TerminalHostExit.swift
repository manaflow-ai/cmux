import Darwin
import Foundation
import CmuxNextDaemon

/// A terminal's host process (`cmux-tui __terminal-host`, one per terminal) and its exit: the
/// observable end of a terminal that the daemon reaped or closed, for tests that check whether a
/// shell outlived its last tab. Nonisolated: the exit handler runs on a dispatch queue, never on
/// the main actor this test target defaults to.
nonisolated struct TerminalHostExit {
    /// The host pid that the owner's discovery record names for `terminal`
    /// (`<state>/terminal-hosts-*/<terminal id>.json`, `host_pid`); nil when no record names it.
    static func hostPID(of terminal: TerminalID, state: URL) -> Int32? {
        let files = FileManager.default
        let roots = (try? files.contentsOfDirectory(at: state, includingPropertiesForKeys: nil)) ?? []
        for root in roots where root.lastPathComponent.hasPrefix("terminal-hosts-") {
            let record = root.appendingPathComponent("\(terminal.rawValue).json")
            guard let data = try? Data(contentsOf: record),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (object["host_pid"] as? NSNumber)?.int32Value else { continue }
            return pid
        }
        return nil
    }

    /// Whether `pid` exits within `bound`. The exit is a kernel event (a process source), so the
    /// wait ends when the process ends; `bound` only limits a process that keeps running.
    static func exits(_ pid: Int32, within bound: Duration) async -> Bool {
        let (exits, sink) = AsyncStream.makeStream(of: Bool.self)
        // DispatchSource process exit: no async Foundation API reports another process's exit.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { @Sendable in sink.yield(true) }
        source.activate()
        defer { source.cancel() }
        // A pid that already ended before the source armed sends no event.
        if kill(pid, 0) != 0 && errno == ESRCH { sink.yield(true) }
        // A deadline, not a poll: it ends the wait for a process that never exits.
        let deadline = Task {
            try? await ContinuousClock().sleep(for: bound)
            sink.yield(false)
        }
        defer { deadline.cancel() }
        for await exited in exits { return exited }
        return false
    }
}
