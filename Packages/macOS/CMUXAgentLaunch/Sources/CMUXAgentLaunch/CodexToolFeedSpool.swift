import Foundation
import Darwin
@preconcurrency import Dispatch

/// Owns bounded tool telemetry files and watches their Codex process lifetime.
///
/// Construct this with a private directory created by the Codex wrapper. Tests
/// can use an isolated temporary directory without a running cmux application.
public actor CodexToolFeedSpool {
    private let directory: URL
    private var directorySource: DispatchSourceFileSystemObject?
    private var processSource: DispatchSourceProcess?

    /// Binds the consumer to one invocation's private directory.
    ///
    /// - Parameter directory: A directory owned by the caller, with mode 0700.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Observes completed publications until the owning process exits.
    ///
    /// - Parameter parentPID: The immediate parent whose exec becomes Codex.
    /// - Returns: Coalesced wakeups, including an initial drain; finishes on exit.
    public func changes(parentPID: Int32) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let fd = open(directory.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            if fd >= 0 { Darwin.close(fd) }
            continuation.finish()
            return stream
        }
        // DispatchSource is the OS file/process notification seam; callers
        // consume only AsyncStream and actor-isolated spool operations.
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
        // rejecting PID reuse: the forwarder must still be its direct child.
        if getppid() != parentPID { continuation.finish() }
        else { continuation.yield(()) }
        return stream
    }

    /// Admits an older installed CLI hook without opening an app connection.
    ///
    /// - Parameters:
    ///   event: Either `pre-tool-use` or `post-tool-use`.
    ///   payload: Original JSON, limited to 64 KiB.
    ///   producerPID: The calling hook process, used to choose a bounded slot.
    public func publish(event: String, payload: Data, producerPID: Int32) {
        guard event == "pre-tool-use" || event == "post-tool-use",
              payload.count <= 65536, producerPID > 0 else { return }
        let slot = Int(producerPID) % 32
        let path = directory.appendingPathComponent(String(slot)).path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        let record = Data("\(event)\n".utf8) + payload + Data([0])
        let written = record.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == record.count else { unlink(path); return }
        let marker = open(directory.appendingPathComponent("\(slot).ready").path,
                          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if marker >= 0 { Darwin.close(marker) }
    }

    /// Consumes up to 32 completed records in publication order.
    ///
    /// Incomplete records stay owned by their producer. Malformed or oversized
    /// records are discarded. No filename outside the fixed slot set is read.
    ///
    /// - Returns: The hook event and original bounded JSON bytes for each record.
    public func drain() -> [(event: String, payload: Data)] {
        let ready = (0..<32).compactMap { slot -> (Int, timespec)? in
            var info = stat()
            let path = directory.appendingPathComponent("\(slot).ready").path
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return (slot, info.st_mtimespec)
        }.sorted {
            if $0.1.tv_sec != $1.1.tv_sec { return $0.1.tv_sec < $1.1.tv_sec }
            return $0.1.tv_nsec < $1.1.tv_nsec
        }
        return ready.compactMap { slot, _ in
            let path = directory.appendingPathComponent(String(slot)).path
            // Remove the marker before releasing the payload slot, so a new
            // writer cannot collide with the previous generation's marker.
            defer {
                unlink(directory.appendingPathComponent("\(slot).ready").path)
                unlink(path)
            }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size > 0, info.st_size <= 65536 + 32 else { return nil }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count == bytes.count, bytes.last == 0,
                  let newline = bytes.firstIndex(of: 10),
                  let event = String(bytes: bytes[..<newline], encoding: .utf8),
                  event == "pre-tool-use" || event == "post-tool-use" else { return nil }
            return (event, Data(bytes[(newline + 1)..<(bytes.count - 1)]))
        }
    }

    /// Stops OS observers and removes only this protocol's private files.
    public func close() {
        stopWatching()
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return }
        for slot in 0..<32 {
            unlink(directory.appendingPathComponent("\(slot).ready").path)
            unlink(directory.appendingPathComponent(String(slot)).path)
        }
        rmdir(directory.path)
    }

    private func stopWatching() {
        directorySource?.cancel()
        processSource?.cancel()
        directorySource = nil
        processSource = nil
    }
}
