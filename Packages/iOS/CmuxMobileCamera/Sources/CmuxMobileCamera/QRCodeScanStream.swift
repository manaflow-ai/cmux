import Foundation

/// An `AsyncStream<String>` of decoded QR-code payloads.
///
/// The capture stack (``QRCodeCaptureController``) yields each accepted QR
/// string into this stream; consumers iterate ``codes`` to react to scans
/// without an `AVCaptureMetadataOutputObjectsDelegate` callback on the view.
/// The stream is buffered-unbounded and yields at most one accepted code per
/// physical scan (deduplication is enforced upstream in the controller).
///
/// Construct one without a capture session to drive synthetic codes in tests:
///
/// ```swift
/// let stream = QRCodeScanStream()
/// stream.yield("cmux-ios://example")
/// stream.finish()
/// ```
public struct QRCodeScanStream: Sendable {
    /// The async sequence of accepted QR payloads.
    public let codes: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    /// Creates a scan stream and its backing continuation.
    public init() {
        var capturedContinuation: AsyncStream<String>.Continuation!
        codes = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
    }

    /// Yields one decoded QR payload to consumers.
    public func yield(_ code: String) {
        continuation.yield(code)
    }

    /// Ends the stream; consumers' `for await` loops complete.
    public func finish() {
        continuation.finish()
    }
}
