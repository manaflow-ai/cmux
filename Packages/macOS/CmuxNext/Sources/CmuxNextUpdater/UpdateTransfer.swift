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

    /// The card's detail: " 12.4 MB of 248.1 MB ·  5%", "12.4 MB" while the size is unknown, or nil
    /// when no byte counts apply. Both counts are in the size's unit with one decimal, and the received
    /// count and the percent are padded with figure spaces to the size's and "100%"'s widths, so in a
    /// tabular-digit font (`Typography.captionDigits`) nothing on the line moves while it counts (Leo
    /// 2026-11-05: "why is it that as the left number grows, it just keeps shifting?").
    public var bytesText: String? {
        guard stage == .downloading, let received = receivedBytes else { return nil }
        guard let expected = expectedBytes, fraction != nil else { return Self.bytes(received, unit: Self.unit(for: received)) }
        let unit = Self.unit(for: expected)
        let total = Self.bytes(expected, unit: unit)
        let got = Self.padded(Self.bytes(min(received, expected), unit: unit), toWidthOf: total)
        let percentStyle = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
        // Whole percent from the byte counts, floored, so it reads 100% only once every byte is in. Integers:
        // a Double fraction floored under-reads an exact one (29 of 50 is 57.999…%).
        // The product is 128-bit (`multipliedFullWidth`), so the floor is exact at any size.
        let percentage = expected.dividingFullWidth(min(received, expected).multipliedFullWidth(by: 100)).quotient
        let percent = Self.padded((Double(percentage) / 100).formatted(percentStyle), toWidthOf: 1.0.formatted(percentStyle))
        return UpdaterStrings.downloadedOf(got, total, percent)
    }

    /// The decimal unit `bytes` reads in (as Finder's file sizes): kB under a megabyte, MB under a gigabyte, else GB.
    static func unit(for bytes: UInt64) -> UnitInformationStorage {
        bytes < 1_000_000 ? .kilobytes : bytes < 1_000_000_000 ? .megabytes : .gigabytes
    }

    /// `bytes` in `unit` with one decimal, always: "115.0 MB", never "115 MB" beside "115.4 MB".
    static func bytes(_ bytes: UInt64, unit: UnitInformationStorage) -> String {
        Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes).converted(to: unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    /// `text` with figure spaces (a digit's width) before it, up to `reference`'s length.
    static func padded(_ text: String, toWidthOf reference: String) -> String {
        String(repeating: "\u{2007}", count: max(0, reference.count - text.count)) + text
    }
}
