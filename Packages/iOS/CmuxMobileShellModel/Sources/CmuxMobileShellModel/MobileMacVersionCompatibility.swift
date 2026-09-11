import Foundation

/// The channel-specific result of comparing a Mac's reported version with the
/// minimum advertised to the current iOS build.
public struct MobileMacVersionCompatibility: Equatable, Sendable {
    /// Whether the reported version fails the selected minimum requirement.
    public let isOutdated: Bool
    /// The selected minimum to display when the Mac is outdated.
    public let requiredVersionDisplay: String?

    /// Compares a reported Mac version with the stable or nightly floor.
    public init(
        appVersion: String?,
        releaseTrack: String?,
        stableMinimum: String?,
        nightlyMinimum: String?
    ) {
        let result = mobileMacVersionCompatibility(
            appVersion: appVersion,
            releaseTrack: releaseTrack,
            stableMinimum: stableMinimum,
            nightlyMinimum: nightlyMinimum
        )
        isOutdated = result.isOutdated
        requiredVersionDisplay = result.requiredVersionDisplay
    }

    fileprivate init(isOutdated: Bool, requiredVersionDisplay: String?) {
        self.isOutdated = isOutdated
        self.requiredVersionDisplay = requiredVersionDisplay
    }
}

private func mobileMacVersionCompatibility(
    appVersion: String?,
    releaseTrack: String?,
    stableMinimum: String?,
    nightlyMinimum: String?
) -> MobileMacVersionCompatibility {
    let normalizedAppVersion = appVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
    let nightly = releaseTrack?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "nightly"
        || (releaseTrack == nil && normalizedAppVersion?.contains("-nightly.") == true)
    if nightly {
        guard let nightlyMinimum,
              let required = parseMobileMacNightlyVersion(nightlyMinimum)
        else { return MobileMacVersionCompatibility(isOutdated: false, requiredVersionDisplay: nil) }
        guard let normalizedAppVersion,
              let installed = parseMobileMacNightlyVersion(normalizedAppVersion)
        else {
            return MobileMacVersionCompatibility(isOutdated: true, requiredVersionDisplay: nightlyMinimum)
        }
        let outdated = mobileMacVersionPrecedes(installed.base, required.base)
            || (installed.base == required.base && installed.build < required.build)
        return MobileMacVersionCompatibility(isOutdated: outdated, requiredVersionDisplay: outdated ? nightlyMinimum : nil)
    }
    guard let stableMinimum,
          let required = parseMobileMacNumericVersion(stableMinimum)
    else { return MobileMacVersionCompatibility(isOutdated: false, requiredVersionDisplay: nil) }
    guard let normalizedAppVersion,
          let installed = parseMobileMacNumericVersion(normalizedAppVersion),
          !normalizedAppVersion.contains("-nightly.")
    else {
        return MobileMacVersionCompatibility(isOutdated: true, requiredVersionDisplay: stableMinimum)
    }
    let outdated = mobileMacVersionPrecedes(installed, required)
    return MobileMacVersionCompatibility(isOutdated: outdated, requiredVersionDisplay: outdated ? stableMinimum : nil)
}

private func parseMobileMacNumericVersion(_ raw: String) -> [Int]? {
    let core = raw.split(separator: "+", maxSplits: 1).first.map(String.init) ?? raw
    let parts = core.split(separator: ".", omittingEmptySubsequences: false)
    guard (1 ... 3).contains(parts.count),
          parts.allSatisfy({
              !$0.isEmpty
                  && $0.utf8.allSatisfy { (48 ... 57).contains($0) }
                  && Int($0) != nil
          })
    else { return nil }
    var values = parts.map { Int($0)! }
    while values.count < 3 { values.append(0) }
    return values
}

private func mobileMacVersionPrecedes(_ lhs: [Int], _ rhs: [Int]) -> Bool {
    for index in 0 ..< max(lhs.count, rhs.count) {
        let left = index < lhs.count ? lhs[index] : 0
        let right = index < rhs.count ? rhs[index] : 0
        if left != right { return left < right }
    }
    return false
}

private func parseMobileMacNightlyVersion(_ raw: String) -> (base: [Int], build: UInt64)? {
    let core = raw.split(separator: "+", maxSplits: 1).first.map(String.init) ?? raw
    let marker = "-nightly."
    guard let range = core.range(of: marker),
          let base = parseMobileMacNumericVersion(String(core[..<range.lowerBound]))
    else { return nil }
    let buildText = core[range.upperBound...]
    guard !buildText.isEmpty,
          buildText.utf8.allSatisfy({ (48 ... 57).contains($0) }),
          let build = UInt64(buildText)
    else { return nil }
    return (base, build)
}
