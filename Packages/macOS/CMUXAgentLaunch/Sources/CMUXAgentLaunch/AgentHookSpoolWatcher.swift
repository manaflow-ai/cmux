#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(CmuxLinuxCompat)
import CmuxLinuxCompat
#endif
@preconcurrency import Dispatch

/// Wakes the session forwarder when records are published and ends when the
/// agent process exits.
///
/// Mirrors the Codex tool-feed spool's observer: the OS file and process
/// notification sources are confined to this actor and surfaced as an
/// `AsyncStream`, because those notifications have no native async API.
public actor AgentHookSpoolWatcher {
    private let directory: URL
    #if canImport(Darwin)
    private var directorySource: DispatchSourceFileSystemObject?
    private var processSource: DispatchSourceProcess?
    #else
    // Linux: an inotify read source and a pidfd read source (or a liveness
    // timer on kernels without pidfd_open) stand in for the vnode and
    // process sources.
    private var directorySource: (any DispatchSourceProtocol)?
    private var processSource: (any DispatchSourceProtocol)?
    #endif
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
        #if canImport(Darwin)
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
        #else
        var directoryStatus = stat()
        guard lstat(directory.path, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR else {
            continuation.finish()
            return stream
        }
        let fd = inotify_init1(Int32(IN_CLOEXEC | IN_NONBLOCK))
        let mask = UInt32(IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_FROM
            | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_DONT_FOLLOW | IN_ONLYDIR)
        guard fd >= 0, inotify_add_watch(fd, directory.path, mask) >= 0 else {
            if fd >= 0 { close(fd) }
            continuation.finish()
            return stream
        }
        let files = DispatchSource.makeReadSource(fileDescriptor: fd, queue: nil)
        files.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while read(fd, &buffer, buffer.count) > 0 {}
            Task { [weak self] in await self?.directoryChanged() }
        }
        files.setCancelHandler { close(fd) }
        let process: any DispatchSourceProtocol
        let pidfd = LinuxProcFS.pidfdOpen(parentPID)
        if pidfd >= 0 {
            // A pidfd becomes readable when the process exits.
            let exits = DispatchSource.makeReadSource(fileDescriptor: pidfd, queue: nil)
            exits.setEventHandler { continuation.finish() }
            exits.setCancelHandler { close(pidfd) }
            process = exits
        } else {
            // No pidfd_open: reparenting is the exit signal for our parent.
            let liveness = DispatchSource.makeTimerSource(queue: nil)
            liveness.schedule(deadline: .now() + 0.5, repeating: 0.5)
            liveness.setEventHandler {
                if getppid() != parentPID { continuation.finish() }
            }
            process = liveness
        }
        directorySource = files
        processSource = process
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopWatching() }
        }
        files.resume()
        process.resume()
        #endif
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
