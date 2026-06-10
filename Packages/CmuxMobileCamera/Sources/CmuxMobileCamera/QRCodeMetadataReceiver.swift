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
    private let onRejected: (@MainActor (String) -> Void)?
    private var didScan = false
    /// The last rejected payload, kept so a non-pairing QR sitting in front of
    /// the camera (which re-decodes on every frame) reports once, not per frame.
    private var lastRejectedValue: String?

    /// Creates a metadata receiver.
    /// - Parameters:
    ///   - stream: The scan stream accepted codes are yielded into.
    ///   - accepts: Predicate deciding whether a decoded string is an accepted
    ///     pairing payload.
    ///   - onRejected: Called once per distinct decoded QR whose payload fails
    ///     `accepts` (a website QR, a Wi-Fi code), so the UI can explain why
    ///     nothing happened instead of silently ignoring the scan.
    init(
        stream: QRCodeScanStream,
        accepts: @escaping @Sendable (String) -> Bool,
        onRejected: (@MainActor (String) -> Void)? = nil
    ) {
        self.stream = stream
        self.accepts = accepts
        self.onRejected = onRejected
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
            guard !didScan else { return }
            guard accepts(value) else {
                if lastRejectedValue != value {
                    lastRejectedValue = value
                    onRejected?(value)
                }
                return
            }
            didScan = true
            stream.yield(value)
        }
    }
}
#endif
