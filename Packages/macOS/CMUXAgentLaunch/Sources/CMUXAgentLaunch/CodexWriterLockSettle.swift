import Darwin
import Foundation

/// Re-probes Codex's writer lock while Codex is changing its lock namespace.
///
/// `.changing` means another Codex held the shared coordination lock or
/// swapped a lock file during the probe. A relaunch resumes dozens of threads
/// in the same second, each holding coordination briefly, so a single probe
/// often lands in that window even though nobody owns this conversation.
/// Only `.changing` is retried; `.active` and `.unavailable` return at once.
public struct CodexWriterLockSettle: Sendable {
    /// Creates a stateless settling policy.
    public init() {}

    /// About 3.5 seconds, front-loaded: one Codex holds coordination for
    /// milliseconds, while a whole relaunch burst can take a few seconds.
    public static let delays: [TimeInterval] = [0.02, 0.05, 0.1, 0.2, 0.4, 0.8, 1, 1]

    /// Probes until the lock is not `.changing`, or the delay budget is spent.
    ///
    /// - Parameters:
    ///   - delays: the longest wait before each re-probe; its count bounds the probes.
    ///   - awaitChange: waits at most the given interval for the namespace to change.
    ///   - probe: one nonblocking lock inspection.
    /// - Returns: The first settled observation, or the last `.changing` one.
    public func inspection(
        delays: [TimeInterval] = Self.delays,
        awaitChange: (CodexWriterLockInspection, TimeInterval) -> Void = Self.awaitNamespaceChange,
        probe: () -> CodexWriterLockInspection
    ) -> CodexWriterLockInspection {
        var inspection = probe()
        for delay in delays where inspection.state == .changing {
            awaitChange(inspection, delay)
            inspection = probe()
        }
        return inspection
    }

    /// Returns when Codex creates, renames, or unlinks a thread lock, or after `timeout`.
    ///
    /// Releasing a flock produces no file event, so the timeout is the
    /// re-probe bound rather than a guess at when the writer finishes.
    public static func awaitNamespaceChange(_ inspection: CodexWriterLockInspection, timeout: TimeInterval) {
        let directory = URL(fileURLWithPath: inspection.lockPath).deletingLastPathComponent().path
        let descriptor = open(directory, O_EVTONLY | O_CLOEXEC)
        // `.changing` implies the directory exists; without an event source
        // the bound alone paces the next probe.
        guard descriptor >= 0 else {
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + timeout)
            return
        }
        let changed = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .global(qos: .utility)
        )
        source.setEventHandler { changed.signal() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        defer { source.cancel() }
        _ = changed.wait(timeout: .now() + timeout)
    }
}
