import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit invokes this synchronous delegate off-main.
/// `expectedStops` is the only shared mutable state, and `lock` protects every
/// access. An actor hop would introduce a callback-ordering race between
/// `expectStop(_:)` and `stream(_:didStopWithError:)`.
final class ApplicationCaptureStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let onUnexpectedStop: @Sendable (ObjectIdentifier) -> Void
    private var expectedStops: Set<ObjectIdentifier> = []

    init(onUnexpectedStop: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.onUnexpectedStop = onUnexpectedStop
    }

    func expectStop(_ stream: SCStream) {
        _ = lock.withLock {
            expectedStops.insert(ObjectIdentifier(stream))
        }
    }

    func finishExpectedStop(_ stream: SCStream) {
        _ = lock.withLock {
            expectedStops.remove(ObjectIdentifier(stream))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasExpected = lock.withLock {
            expectedStops.remove(ObjectIdentifier(stream)) != nil
        }
        if !wasExpected {
            onUnexpectedStop(ObjectIdentifier(stream))
        }
    }
}
