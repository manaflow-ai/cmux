/// One machine-readable code detected in a capture frame, reduced to the two
/// facts selection needs. Mirrors `AVMetadataMachineReadableCodeObject`
/// without the AVFoundation type so the selection rule runs under
/// `swift test` off-device.
public struct QRCodeFrameCandidate: Sendable, Equatable {
    /// Whether the detection is a QR code (as opposed to another symbology).
    public let isQRCode: Bool
    /// The decoded payload, when the detector could read one.
    public let stringValue: String?

    /// Creates a candidate from one detection's symbology and decoded value.
    public init(isQRCode: Bool, stringValue: String?) {
        self.isQRCode = isQRCode
        self.stringValue = stringValue
    }
}
