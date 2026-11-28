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
    private var continuation: AsyncStream<Void>.Continuation?

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
        files.setEventHandler { [weak self] in
            Task { [weak self] in await self?.directoryChanged() }
        }
        files.setCancelHandler { Darwin.close(fd) }
        let process = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: nil)
        process.setEventHandler { continuation.finish() }
        directorySource = files
        processSource = process
        self.continuation = continuation
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

    /// Schedules one recovery drain. File changes coalesce while it is pending;
    /// no timer runs after a successful drain or after the parent exits.
    public func retry(after delay: TimeInterval) {
        guard continuation != nil, retrySource == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: nil)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { [weak self] in await self?.retryReady() }
        }
        retrySource = timer
        timer.resume()
    }

    private func directoryChanged() {
        guard retrySource == nil else { return }
        continuation?.yield(())
    }

    private func retryReady() {
        retrySource?.cancel()
        retrySource = nil
        continuation?.yield(())
    }

    private func stopWatching() {
        directorySource?.cancel()
        processSource?.cancel()
        retrySource?.cancel()
        directorySource = nil
        processSource = nil
        retrySource = nil
        continuation = nil
    }
}
