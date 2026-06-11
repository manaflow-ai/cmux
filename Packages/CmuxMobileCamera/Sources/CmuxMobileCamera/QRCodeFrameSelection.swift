/// One machine-readable code detected in a capture frame, reduced to the two
/// facts selection needs. Mirrors `AVMetadataMachineReadableCodeObject`
/// without the AVFoundation type so the selection rule runs under
/// `swift test` off-device.
public struct QRCodeFrameCandidate: Sendable, Equatable {
    /// Whether the detection is a QR code (as opposed to another symbology).
    public let isQRCode: Bool
    /// The decoded payload, when the detector could read one.
    public let stringValue: String?

    public init(isQRCode: Bool, stringValue: String?) {
        self.isQRCode = isQRCode
        self.stringValue = stringValue
    }
}

/// Picks the pairing payload out of one frame's detections.
public struct QRCodeFrameSelection: Sendable {
    /// Creates the selector. It is stateless: construct one inline at the
    /// call site.
    public init() {}

    /// Returns the first accepted QR payload among `candidates`, or `nil`.
    ///
    /// A frame can carry several detections at once: two codes side by side,
    /// or another detection ordered before the QR. Stopping at the frame's
    /// first object would make scanning fail outright whenever the pairing
    /// code is not detection number zero, so every candidate is considered.
    public func firstAcceptedCode(
        in candidates: [QRCodeFrameCandidate],
        accepts: (String) -> Bool
    ) -> String? {
        for candidate in candidates where candidate.isQRCode {
            guard let value = candidate.stringValue, accepts(value) else { continue }
            return value
        }
        return nil
    }
}
