internal import Foundation

/// A Mac build version stamp as reported through authenticated host status:
/// either a released dotted version (`0.64.22`) or a nightly stamp
/// (`0.64.22-nightly.3345650013201`, where the counter is the GitHub run id
/// plus a two-digit attempt and is therefore globally monotonic).
public struct MobileMacBuildVersionStamp: Equatable, Sendable {
    /// The dotted numeric base version.
    public let base: MobileMacAppVersion
    /// The monotonic nightly build counter, present only on nightly stamps.
    public let nightlyBuild: UInt64?

    /// Parses a reported marketing version, accepting the released and the
    /// nightly grammar only. Anything else (empty, custom suffixes) is `nil`.
    ///
    /// - Parameter string: The marketing version reported by the Mac.
    public init?(parsing string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let released = MobileMacAppVersion(parsing: trimmed) {
            base = released
            nightlyBuild = nil
            return
        }
        let marker = "-nightly."
        guard let markerRange = trimmed.range(of: marker),
              let parsedBase = MobileMacAppVersion(parsing: String(trimmed[..<markerRange.lowerBound]))
        else {
            return nil
        }
        let counter = trimmed[markerRange.upperBound...]
        guard !counter.isEmpty,
              counter.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let build = UInt64(counter)
        else {
            return nil
        }
        base = parsedBase
        nightlyBuild = build
    }
}
