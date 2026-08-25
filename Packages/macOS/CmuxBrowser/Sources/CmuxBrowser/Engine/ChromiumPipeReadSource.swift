import Darwin
import Foundation

/// Owns a nonblocking Chromium pipe and delivers readiness callbacks on a
/// private dispatch queue.
///
/// `DispatchSource.makeReadSource` is the low-level pipe-I/O carve-out: there
/// is no async-native API that can await readiness without occupying a Swift
/// cooperative-pool thread. The source owns and closes the descriptor exactly
/// once when cancelled.
// SAFETY: the dispatch source owns the descriptor and all callbacks execute
// on its private serial queue; cancellation is idempotent.
final class ChromiumPipeReadSource: @unchecked Sendable {
    // SAFETY: only the source queue reads the weak cancellation reference.
    private final class SourceReference: @unchecked Sendable {
        weak var source: (any DispatchSourceRead)? = nil
    }

    private let source: any DispatchSourceRead

    init(
        descriptor: Int32,
        label: String,
        readHandler: @escaping @Sendable () -> Bool
    ) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            throw error
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: label, qos: .userInitiated)
        )
        let reference = SourceReference()
        source.setEventHandler {
            if !readHandler() {
                reference.source?.cancel()
            }
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        self.source = source
        reference.source = source
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}

/// Incrementally decodes one delimiter-framed Chromium pipe on its source
/// queue. The mutable buffer is never accessed from another queue.
// SAFETY: `pending` and `buffer` are accessed only by the read source's
// private serial queue; callers exchange completed frames via Sendable values.
final class ChromiumPipeReadBuffer: @unchecked Sendable {
    private let delimiter: UInt8
    private let maximumPendingBytes: Int
    private var pending = Data()
    private var buffer = [UInt8](repeating: 0, count: 16 * 1024)

    init(delimiter: UInt8, maximumPendingBytes: Int) {
        self.delimiter = delimiter
        self.maximumPendingBytes = max(1, maximumPendingBytes)
    }

    /// Reads until the descriptor would block or reaches EOF.
    ///
    /// - Returns: `true` while the source should remain armed.
    func read(
        from descriptor: Int32,
        onMessage: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (_ hasPartialMessage: Bool, _ errorCode: Int32?) -> Void
    ) -> Bool {
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                pending.append(contentsOf: buffer.prefix(count))
                while let delimiterIndex = pending.firstIndex(of: delimiter) {
                    onMessage(Data(pending[..<delimiterIndex]))
                    pending.removeSubrange(...delimiterIndex)
                }
                if pending.count > maximumPendingBytes {
                    onEnd(true, nil)
                    return false
                }
                continue
            }

            if count < 0, errno == EINTR {
                continue
            }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return true
            }
            if count < 0 {
                onEnd(!pending.isEmpty, errno)
            } else {
                onEnd(!pending.isEmpty, nil)
            }
            return false
        }
    }
}
