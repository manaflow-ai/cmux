import CmuxNextCompat
import Darwin
import Foundation

/// The startup trace's file: opened on the first drain and written only by drains, which run on the
/// ``BackgroundWork`` files lane, never on the main thread. One drain holds it at a time (it is taken out
/// of the trace's state for the drain), so no lock is held across its I/O.
struct StartupTraceFile: Sendable {
    let url: URL
    let chunkBytes: Int
    private(set) var encoder: StartupTraceEncoder
    private var descriptor: Int32 = -1
    private var opened = false
    /// Why the file could not be opened or written (`errno`'s text); later records are dropped.
    private(set) var failure: String?
    private let mainThread: UInt64?

    init(url: URL, pid: Int32, chunkBytes: Int, mainThread: UInt64?) {
        self.url = url
        self.chunkBytes = chunkBytes
        self.mainThread = mainThread
        encoder = StartupTraceEncoder(pid: pid, reserve: chunkBytes)
    }

    /// Events written to the file (the header's metadata included).
    var events: Int { failure == nil ? encoder.eventCount : 0 }

    /// Encodes `records` and writes them in writes of about ``chunkBytes``, each ending on an event.
    mutating func write(_ records: [StartupTraceRecord]) {
        openIfNeeded()
        for record in records {
            encoder.append(record)
            if encoder.bytes.count >= chunkBytes { writeEncoded() }
        }
        writeEncoded()
    }

    /// Writes the closing event and `]`, and closes the descriptor.
    mutating func close(at nanos: UInt64, dropped: Int) {
        openIfNeeded()
        encoder.footer(at: nanos, dropped: dropped)
        writeEncoded()
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private mutating func openIfNeeded() {
        guard !opened else { return }
        opened = true
        do {
            try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            failure = error.localizedDescription
            return
        }
        let fd = blockingOpen(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            failure = String(cString: strerror(errno))
            return
        }
        descriptor = fd
        encoder.header(mainThread: mainThread)
    }

    private mutating func writeEncoded() {
        defer { encoder.clear() }
        guard descriptor >= 0, !encoder.bytes.isEmpty else { return }
        if let error = Self.writeAll(descriptor, encoder.bytes) {
            failure = String(cString: strerror(error))
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    /// Writes every byte (a short write continues); returns `errno` on a failure.
    private static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Int32? {
        bytes.withUnsafeBytes { raw -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < raw.count {
                let written = blockingWrite(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return written < 0 ? errno : EIO
                }
            }
            return nil
        }
    }
}
