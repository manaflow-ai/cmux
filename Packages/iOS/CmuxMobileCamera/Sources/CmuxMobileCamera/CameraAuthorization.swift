@preconcurrency public import AVFoundation

/// Async seam over `AVCaptureDevice` video-capture authorization.
///
/// Wraps the callback-based `AVCaptureDevice.requestAccess(for:)` in an
/// `async` API so SwiftUI view code can `await` the result instead of bridging
/// a completion handler at the call site. Reads of the current status stay
/// synchronous because `AVCaptureDevice.authorizationStatus(for:)` is itself
/// synchronous and side-effect-free.
public struct CameraAuthorization: Sendable {
    /// Creates a camera-authorization seam.
    public init() {}

    /// The current video-capture authorization status for this process.
    public var videoStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Requests video-capture authorization from the user.
    ///
    /// - Returns: The resolved status after the prompt: `.authorized` when the
    ///   user grants access, otherwise the prevailing status (`.denied` etc.).
    @discardableResult
    public func requestVideoAccess() async -> AVAuthorizationStatus {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
    }
}
