import Foundation

/// How far a found update has come on its way to being staged (Lawrence
/// 2026-10-20: Check for Updates, then Attempt Update "needs better loading
/// indicator"): Sparkle starting the download, the bytes received, then the
/// archive being verified and unpacked. The notice card names the stage and
/// shows the bytes and the measured fraction, so a download never looks
/// stalled and unpacking never looks like a second download.
nonisolated public struct UpdateTransfer: Equatable, Sendable {
    /// Where the update is.
    public enum Stage: Equatable, Sendable {
        /// Sparkle asked for the archive; no byte arrived yet.
        case starting
        /// Bytes arrive (``UpdateTransfer/receivedBytes``).
        case downloading
        /// The archive is verified and unpacked.
        case preparing
    }

    public var stage: Stage
    /// Bytes received; nil before the download starts and while preparing.
    public var receivedBytes: UInt64?
    /// The archive's size, nil while the server did not say.
    public var expectedBytes: UInt64?
    /// Progress through this stage, 0...1, or nil while unmeasured.
    public var fraction: Double?

    public init(stage: Stage, receivedBytes: UInt64? = nil, expectedBytes: UInt64? = nil, fraction: Double? = nil) {
        self.stage = stage
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.fraction = fraction.map { min(1, max(0, $0)) }
    }

    /// Sparkle asked for the archive.
    public static let starting = UpdateTransfer(stage: .starting)

    /// `received` of `expected` bytes; the fraction is nil while the size is unknown.
    public static func downloading(received: UInt64, expected: UInt64?) -> UpdateTransfer {
        let size = expected.flatMap { $0 > 0 ? $0 : nil }
        return UpdateTransfer(stage: .downloading, receivedBytes: received, expectedBytes: size,
                              fraction: size.map { Double(received) / Double($0) })
    }

    /// Verifying and unpacking, `fraction` done (nil while unmeasured).
    public static func preparing(_ fraction: Double?) -> UpdateTransfer {
        UpdateTransfer(stage: .preparing, fraction: fraction)
    }

    /// The card's detail: "12.4 MB of 48.1 MB · 26%", "12.4 MB" while the
    /// size is unknown, or nil when no byte counts apply.
    public var bytesText: String? {
        guard stage == .downloading, let received = receivedBytes else { return nil }
        let format = ByteCountFormatStyle(style: .file)
        let got = format.format(Int64(clamping: received))
        guard let expected = expectedBytes, let fraction else { return got }
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return UpdaterStrings.downloadedOf(got, format.format(Int64(clamping: expected)), percent)
    }
}
