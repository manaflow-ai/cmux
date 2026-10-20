import Foundation

/// Pure wire-size budget used by browser image encoders.
public struct MobileBrowserFrameSizeBudget: Equatable, Sendable {
    /// Default maximum base64 payload, leaving JSON headroom under the 8 MiB frame cap.
    public static let defaultMaximumBase64Bytes = 6 * 1024 * 1024

    /// Maximum base64 character count allowed for image data.
    public let maximumBase64Bytes: Int

    /// Creates a frame-size budget.
    public init(maximumBase64Bytes: Int = Self.defaultMaximumBase64Bytes) {
        precondition(maximumBase64Bytes > 0)
        self.maximumBase64Bytes = maximumBase64Bytes
    }

    /// Returns the base64 character count for an encoded byte count.
    public func base64ByteCount(forEncodedByteCount byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        return ((byteCount + 2) / 3) * 4
    }

    /// Returns whether encoded image bytes fit the wire budget after base64 expansion.
    public func contains(encodedByteCount: Int) -> Bool {
        base64ByteCount(forEncodedByteCount: encodedByteCount) <= maximumBase64Bytes
    }

    /// Chooses a bounded linear downscale factor from the observed size overshoot.
    public func downscaleFactor(encodedByteCount: Int) -> Double {
        guard encodedByteCount > 0, !contains(encodedByteCount: encodedByteCount) else { return 1 }
        let ratio = Double(maximumBase64Bytes) / Double(base64ByteCount(forEncodedByteCount: encodedByteCount))
        return min(0.9, max(0.25, sqrt(ratio) * 0.92))
    }
}
