#if os(macOS)
import Foundation
import ScreenCaptureKit

/// Calls `onStop` when ScreenCaptureKit stops a stream with an error.
final class CaptureStopDelegate: NSObject, SCStreamDelegate, Sendable {
    private let onStop: @Sendable () -> Void

    init(onStop: @escaping @Sendable () -> Void) {
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop()
    }
}
#endif
