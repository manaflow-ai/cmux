import Foundation

extension BuildFlavor {
    /// The release-channel flavors that ship as their own signed bundles next
    /// to stable. Order matters: nightly is checked before rc so the same
    /// precedence applies to bundle identifiers and to bundle-name tokens.
    private static let releaseChannels: [BuildFlavor] = [.nightly, .rc]

    /// Detects a release channel from the bundle identifier first
    /// (`com.cmuxterm.app.<channel>` or a tagged `com.cmuxterm.app.<channel>.<slug>`),
    /// then from a channel token in any of the bundle names ("cmux NIGHTLY",
    /// "cmux RC"). Returns nil for stable and for identifiers that belong to
    /// no channel, so `detect` can fall through to `.stable`.
    ///
    /// - Parameters:
    ///   - normalizedBundleIdentifier: The trimmed, lowercased bundle identifier.
    ///   - bundleNames: The bundle name candidates.
    /// - Returns: The matching channel, or `nil`.
    public static func releaseChannel(normalizedBundleIdentifier: String?, bundleNames: [String]) -> BuildFlavor? {
        for channel in releaseChannels {
            let identifier = "com.cmuxterm.app.\(channel.rawValue)"
            if normalizedBundleIdentifier == identifier
                || normalizedBundleIdentifier?.hasPrefix("\(identifier).") == true {
                return channel
            }
        }
        for channel in releaseChannels {
            let token = channel.rawValue.uppercased()
            if bundleNames.contains(where: { containsToken(token, in: $0) }) {
                return channel
            }
        }
        return nil
    }
}
