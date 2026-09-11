import Foundation

/// The channel-specific result of comparing a Mac's reported version with the
/// minimum advertised to the current iOS build.
public struct MobileMacVersionCompatibility: Equatable, Sendable {
    public let isOutdated: Bool
    public let requiredVersionDisplay: String?

    public init(isOutdated: Bool, requiredVersionDisplay: String?) {
        self.isOutdated = isOutdated
        self.requiredVersionDisplay = requiredVersionDisplay
    }
}

/// Single comparison authority shared by connection admission and UI warning
/// state. Missing or malformed Mac versions fail closed when a floor exists.
public enum MobileMacVersionCompatibilityEvaluator {
    public static func evaluate(
        appVersion: String?,
        releaseTrack: String?,
        stableMinimum: String?,
        nightlyMinimum: String?
    ) -> MobileMacVersionCompatibility {
        let nightly = releaseTrack?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "nightly"
            || (releaseTrack == nil && appVersion?.contains("-nightly.") == true)
        if nightly {
            guard let nightlyMinimum,
                  let required = parseNightly(nightlyMinimum)
            else { return MobileMacVersionCompatibility(isOutdated: false, requiredVersionDisplay: nil) }
            guard let appVersion,
                  let installed = parseNightly(appVersion)
            else {
                return MobileMacVersionCompatibility(isOutdated: true, requiredVersionDisplay: nightlyMinimum)
            }
            let outdated = lexicographicallyPrecedes(installed.base, required.base)
                || (installed.base == required.base && installed.build < required.build)
            return MobileMacVersionCompatibility(isOutdated: outdated, requiredVersionDisplay: outdated ? nightlyMinimum : nil)
        }
        guard let stableMinimum,
              let required = parseNumeric(stableMinimum)
        else { return MobileMacVersionCompatibility(isOutdated: false, requiredVersionDisplay: nil) }
        guard let appVersion,
              let installed = parseNumeric(appVersion),
              !appVersion.contains("-nightly.")
        else {
            return MobileMacVersionCompatibility(isOutdated: true, requiredVersionDisplay: stableMinimum)
        }
        let outdated = lexicographicallyPrecedes(installed, required)
        return MobileMacVersionCompatibility(isOutdated: outdated, requiredVersionDisplay: outdated ? stableMinimum : nil)
    }

    private static func parseNumeric(_ raw: String) -> [Int]? {
        let core = raw.split(separator: "+", maxSplits: 1).first.map(String.init) ?? raw
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else { return nil }
        var values = parts.map { Int($0)! }
        while values.count < 3 { values.append(0) }
        return values
    }

    private static func lexicographicallyPrecedes(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for index in 0 ..< max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func parseNightly(_ raw: String) -> (base: [Int], build: UInt64)? {
        let core = raw.split(separator: "+", maxSplits: 1).first.map(String.init) ?? raw
        let marker = "-nightly."
        guard let range = core.range(of: marker),
              let base = parseNumeric(String(core[..<range.lowerBound]))
        else { return nil }
        let buildText = core[range.upperBound...]
        guard !buildText.isEmpty,
              buildText.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let build = UInt64(buildText)
        else { return nil }
        return (base, build)
    }
}
