import Darwin
import Foundation
@preconcurrency import Dispatch

/// Wakes the session forwarder when records are published and ends when the
/// agent process exits.
///
/// Mirrors the Codex tool-feed spool's observer: the OS file and process
/// notification sources are confined to this actor and surfaced as an
/// `AsyncStream`, because those notifications have no native async API.
public actor AgentHookSpoolWatcher {
    private let directory: URL
    private var directorySource: DispatchSourceFileSystemObject?
    private var processSource: DispatchSourceProcess?
    private var retrySource: DispatchSourceTimer?

    /// Binds the watcher to one spool directory.
    ///
    /// - Parameter directory: The session's private spool directory.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Observes directory changes until the agent process exits.
    ///
    /// - Parameter parentPID: The forwarder's parent, which execs into the agent.
    /// - Returns: Coalesced wakeups, starting with one initial drain. The stream
    ///   finishes when the parent exits or is no longer this process's parent.
    public func changes(parentPID: Int32, retryInterval: TimeInterval? = nil) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let fd = open(directory.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            continuation.finish()
            return stream
        }
        // DispatchSource is the OS file/process notification seam; callers see
        // only the AsyncStream.
        let files = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: nil
        )
        files.setEventHandler { continuation.yield(()) }
        files.setCancelHandler { Darwin.close(fd) }
        let process = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: nil)
        process.setEventHandler { continuation.finish() }
        let retry: DispatchSourceTimer?
        if let retryInterval, retryInterval > 0 {
            let timer = DispatchSource.makeTimerSource(queue: nil)
            let nanoseconds = DispatchTimeInterval.nanoseconds(Int(retryInterval * 1_000_000_000))
            timer.schedule(deadline: .now() + nanoseconds, repeating: nanoseconds)
            timer.setEventHandler { continuation.yield(()) }
            retry = timer
        } else {
            retry = nil
        }
        directorySource = files
        processSource = process
        retrySource = retry
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopWatching() }
        }
        files.resume()
        process.resume()
        retry?.resume()
        // Registration precedes this check, closing the parent-exit race and
        // rejecting PID reuse: the forwarder must still be the agent's child.
        if getppid() != parentPID {
            continuation.finish()
        } else {
            continuation.yield(())
        }
        return stream
    }

    private func stopWatching() {
        directorySource?.cancel()
        processSource?.cancel()
        retrySource?.cancel()
        directorySource = nil
        processSource = nil
        retrySource = nil
    }
}
