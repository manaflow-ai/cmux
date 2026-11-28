#if os(iOS)
@preconcurrency import AVFoundation
import Foundation

/// Bridges `AVCaptureMetadataOutput`'s delegate callbacks into a
/// ``QRCodeScanStream``.
///
/// Considers every detection in the frame (via ``QRCodeFrameSelection``, so a
/// foreign code or non-QR detection ordered first cannot mask the pairing
/// code), filters to QR codes whose string value satisfies the injected
/// `accepts` predicate, fires at most once (the first accepted code), and
/// yields that code into the stream. The capture session delivers callbacks
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
        let candidates = metadataObjects.map { object in
            QRCodeFrameCandidate(
                isQRCode: object.type == .qr,
                stringValue: (object as? AVMetadataMachineReadableCodeObject)?.stringValue
            )
        }
        MainActor.assumeIsolated {
            guard !didScan,
                  let value = QRCodeFrameSelection().firstAcceptedCode(in: candidates, accepts: accepts)
            else {
                return
            }
            didScan = true
            stream.yield(value)
        }
    }
}
#endif
