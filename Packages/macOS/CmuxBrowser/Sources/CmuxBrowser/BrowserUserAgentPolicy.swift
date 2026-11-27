public import Foundation

/// Selects the browser identity that best matches an embedded WebKit view for
/// each top-level destination.
public struct BrowserUserAgentPolicy: Sendable {
    /// Google Workspace supports only the two most recent browser versions.
    /// Keep the compatibility identity on Apple's current stable Safari even
    /// when the locally installed Safari has not been updated yet.
    private static let minimumAdvertisedSafariVersion = [26, 6]

    /// The policy derived from the Safari installation and operating system on this Mac.
    public static let system = BrowserUserAgentPolicy()

    /// A Safari-compatible user-agent string for sites that gate browser support.
    public let safariCompatibleUserAgent: String

    /// Creates a policy using an explicit installed Safari version.
    ///
    /// Invalid versions fall back to the Safari generation associated with the
    /// current operating system. Versions older than the current compatibility
    /// floor are raised to that floor so support gates do not reject cmux solely
    /// because Safari.app is stale.
    ///
    /// - Parameter safariVersion: A numeric dot-separated Safari version.
    public init(safariVersion: String) {
        let candidateVersion: [Int]
        let installedVersion = Self.versionComponents(from: safariVersion)
        if !installedVersion.isEmpty {
            candidateVersion = installedVersion
        } else {
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            if osVersion.majorVersion >= 26 {
                candidateVersion = [osVersion.majorVersion, osVersion.minorVersion]
            } else if osVersion.majorVersion >= 11 {
                candidateVersion = [osVersion.majorVersion + 3, 0]
            } else {
                candidateVersion = [13, 1]
            }
        }
        let resolvedVersion = Self.isVersion(
            candidateVersion,
            olderThan: Self.minimumAdvertisedSafariVersion
        ) ? Self.minimumAdvertisedSafariVersion : candidateVersion
        safariCompatibleUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/\(resolvedVersion.map(String.init).joined(separator: ".")) Safari/605.1.15"
    }

    /// Creates a policy using the installed Safari version when available.
    public init() {
        let safariBundleURL = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        let installedVersion = Bundle(url: safariBundleURL)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.init(safariVersion: installedVersion ?? "")
    }

    /// Resolves the browser identity policy for a top-level destination.
    ///
    /// Every web destination receives the current Safari-compatible identity.
    /// Non-web destinations have no applicable user-agent policy.
    ///
    /// - Parameter url: The destination of the top-level navigation.
    /// - Returns: The user-agent policy resolution for the destination.
    public func resolution(for url: URL?) -> BrowserUserAgentPolicyResolution {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .notApplicable
        }
        return .custom(safariCompatibleUserAgent)
    }

    /// Parses a numeric dot-separated browser version.
    private static func versionComponents(from string: String) -> [Int] {
        let substrings = string.split(separator: ".", omittingEmptySubsequences: false)
        guard !substrings.isEmpty else { return [] }

        var components: [Int] = []
        components.reserveCapacity(substrings.count)
        for substring in substrings {
            guard !substring.isEmpty, let component = Int(substring), component >= 0 else {
                return []
            }
            components.append(component)
        }
        return components
    }

    /// Compares browser version components with missing trailing components treated as zero.
    private static func isVersion(_ lhs: [Int], olderThan rhs: [Int]) -> Bool {
        let componentCount = max(lhs.count, rhs.count)
        for index in 0..<componentCount {
            let lhsComponent = index < lhs.count ? lhs[index] : 0
            let rhsComponent = index < rhs.count ? rhs[index] : 0
            if lhsComponent != rhsComponent {
                return lhsComponent < rhsComponent
            }
        }
        return false
    }
}
