import Darwin
import Foundation

/// Allocates durable sequence ranges across cmux processes that share the event log.
///
/// The sidecar stores the high-water mark of the latest leased range rather than
/// every sequence. Callers serialize access to the in-memory lease; the file lock
/// still serializes range reservations across processes.
final class CmuxEventSequenceStore: @unchecked Sendable {
    static let defaultBlockSize = 256

    private let stateURL: URL
    private let lockURL: URL
    private let blockSize: Int64
    private var nextSequence: Int64 = 0
    private var reservedThrough: Int64 = 0

    init(eventLogURL: URL, blockSize: Int = CmuxEventSequenceStore.defaultBlockSize) {
        self.stateURL = eventLogURL.appendingPathExtension("seq")
        self.lockURL = eventLogURL.appendingPathExtension("seq.lock")
        self.blockSize = Int64(max(1, blockSize))
    }

    func current() -> Int64 {
        withFileLock { readState() } ?? 0
    }

    func raiseHighWater(to minimum: Int64) {
        guard minimum > 0 else { return }
        _ = withFileLock {
            let current = readState()
            if minimum > current {
                try? writeState(minimum)
            }
        }
        if reservedThrough < minimum {
            nextSequence = 0
            reservedThrough = 0
        }
    }

    /// Returns the next sequence from this process's leased range.
    ///
    /// Range reservation is the only operation that touches the sidecar. The
    /// event bus invokes this method on its utility publication queue, never on
    /// the caller's thread or while holding the bus lock.
    func allocate(minimum: Int64 = 0) -> Int64? {
        if nextSequence > minimum, nextSequence <= reservedThrough {
            let sequence = nextSequence
            nextSequence += 1
            return sequence
        }

        guard let range = reserveRange(count: blockSize, minimum: minimum) else { return nil }
        nextSequence = range.start == Int64.max ? 0 : range.start + 1
        reservedThrough = range.end
        return range.start
    }

    /// Reserves an exact range for recovery rebasing under the sidecar lock.
    func reserve(count: Int, minimum: Int64 = 0) -> (start: Int64, end: Int64)? {
        guard count > 0 else { return nil }
        return reserveRange(count: Int64(count), minimum: minimum)
    }

#if DEBUG
    func resetForTesting() {
        try? FileManager.default.removeItem(at: stateURL)
        nextSequence = 0
        reservedThrough = 0
    }
#endif

    private func reserveRange(count: Int64, minimum: Int64) -> (start: Int64, end: Int64)? {
        withFileLock {
            let current = readState()
            let floor = max(current, minimum)
            guard floor < Int64.max else { return nil }
            let start = floor + 1
            let (end, overflow) = start.addingReportingOverflow(count - 1)
            guard start > 0, !overflow, end >= start else { return nil }
            do {
                try writeState(end)
            } catch {
                return nil
            }
            return (start: start, end: end)
        } ?? nil
    }

    private func withFileLock<T>(_ body: () -> T) -> T? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let handle = try FileHandle(forWritingTo: lockURL)
            defer { try? handle.close() }
            guard flock(handle.fileDescriptor, LOCK_EX) == 0 else { return nil }
            defer { flock(handle.fileDescriptor, LOCK_UN) }
            return body()
        } catch {
            _ = fileManager.createFile(atPath: lockURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: lockURL) else { return nil }
            defer { try? handle.close() }
            guard flock(handle.fileDescriptor, LOCK_EX) == 0 else { return nil }
            defer { flock(handle.fileDescriptor, LOCK_UN) }
            return body()
        }
    }

    private func readState() -> Int64 {
        guard let data = try? Data(contentsOf: stateURL),
              let string = String(data: data, encoding: .utf8),
              let value = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else {
            return 0
        }
        return value
    }

    private func writeState(_ value: Int64) throws {
        try Data("\(value)\n".utf8).write(to: stateURL, options: .atomic)
    }
}
