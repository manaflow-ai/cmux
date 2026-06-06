#if os(iOS)
@preconcurrency import AVFoundation
import Foundation

/// Bridges `AVCaptureMetadataOutput`'s delegate callbacks into a
/// ``QRCodeScanStream``.
///
/// Filters detected metadata to QR codes whose string value satisfies the
/// injected `accepts` predicate, fires at most once (the first accepted code),
/// and yields that code into the stream. The capture session delivers callbacks
/// on the main queue, so this type is `@MainActor`-isolated.
@MainActor
final class QRCodeMetadataReceiver: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private let stream: QRCodeScanStream
    private let accepts: @Sendable (String) -> Bool
    private var didScan = false

    /// Creates a metadata receiver.
    /// - Parameters:
    ///   - stream: The scan stream accepted codes are yielded into.
    ///   - accepts: Predicate deciding whether a decoded string is an accepted
    ///     pairing payload.
    init(stream: QRCodeScanStream, accepts: @escaping @Sendable (String) -> Bool) {
        self.stream = stream
        self.accepts = accepts
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadata.type == .qr,
              let value = metadata.stringValue else {
            return
        }
        MainActor.assumeIsolated {
            guard !didScan, accepts(value) else { return }
            didScan = true
            stream.yield(value)
        }
    }
}
#endif
