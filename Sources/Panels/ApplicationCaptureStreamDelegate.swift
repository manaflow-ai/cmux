import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit invokes this delegate across concurrency domains. Its only
/// mutable value is protected by `lock`, and `onUnexpectedStop` is Sendable.
final class ApplicationCaptureStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let onUnexpectedStop: @Sendable () -> Void
    private var expectedStops: Set<ObjectIdentifier> = []

    init(onUnexpectedStop: @escaping @Sendable () -> Void) {
        self.onUnexpectedStop = onUnexpectedStop
    }

    func expectStop(_ stream: SCStream) {
        lock.withLock {
            expectedStops.insert(ObjectIdentifier(stream))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasExpected = lock.withLock {
            expectedStops.remove(ObjectIdentifier(stream)) != nil
        }
        if !wasExpected {
            onUnexpectedStop()
        }
    }
}
