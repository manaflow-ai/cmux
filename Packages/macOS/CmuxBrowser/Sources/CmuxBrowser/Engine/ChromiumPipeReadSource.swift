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
