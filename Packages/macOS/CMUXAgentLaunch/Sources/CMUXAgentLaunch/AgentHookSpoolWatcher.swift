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
    public func changes(parentPID: Int32) -> AsyncStream<Void> {
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
        directorySource = files
        processSource = process
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopWatching() }
        }
        files.resume()
        process.resume()
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
        directorySource = nil
        processSource = nil
    }
}
