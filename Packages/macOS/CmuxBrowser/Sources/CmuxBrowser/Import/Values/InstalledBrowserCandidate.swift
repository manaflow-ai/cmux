public import Foundation

/// A browser that was detected on the current Mac, together with its resolved
/// engine family, discovered profiles, and a detection-confidence score.
public struct InstalledBrowserCandidate: Identifiable, Hashable, Sendable {
    /// Static metadata for the matched browser.
    public let descriptor: BrowserImportBrowserDescriptor
    /// The engine family resolved from the on-disk data (may differ from the
    /// descriptor's nominal family when data layout disagrees).
    public let resolvedFamily: BrowserImportEngineFamily
    /// The user's home directory that detection ran against.
    public let homeDirectoryURL: URL
    /// Location of the installed application bundle, if found.
    public let appURL: URL?
    /// Location of the browser's data root, if found.
    public let dataRootURL: URL?
    /// Source profiles discovered inside the data root.
    public let profiles: [InstalledBrowserProfile]
    /// Human-readable signals describing how the browser was detected.
    public let detectionSignals: [String]
    /// Confidence score used to rank candidates (higher is stronger).
    public let detectionScore: Int

    /// Stable identifier matching the descriptor's slug.
    public var id: String { descriptor.id }
    /// Human-readable browser name.
    public var displayName: String { descriptor.displayName }
    /// The resolved engine family used when importing this candidate's data.
    public var family: BrowserImportEngineFamily { resolvedFamily }
    /// Convenience list of profile data-directory URLs.
    public var profileURLs: [URL] { profiles.map(\.rootURL) }

    /// Whether a user-supplied lookup string names this browser.
    public func matchesLookupQuery(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if id.lowercased() == normalized { return true }
        if displayName.lowercased() == normalized { return true }
        if descriptor.aliases.contains(where: { $0.lowercased() == normalized }) { return true }
        return descriptor.appNames.contains { appName in
            appName.lowercased() == normalized ||
                appName.replacingOccurrences(of: ".app", with: "").lowercased() == normalized
        }
    }

    /// Creates a detected-browser candidate.
    ///
    /// - Parameters:
    ///   - descriptor: Static metadata for the matched browser.
    ///   - resolvedFamily: Engine family resolved from on-disk data.
    ///   - homeDirectoryURL: Home directory detection ran against.
    ///   - appURL: Location of the application bundle, if found.
    ///   - dataRootURL: Location of the data root, if found.
    ///   - profiles: Source profiles discovered inside the data root.
    ///   - detectionSignals: Signals describing how the browser was detected.
    ///   - detectionScore: Confidence score used for ranking.
    public init(
        descriptor: BrowserImportBrowserDescriptor,
        resolvedFamily: BrowserImportEngineFamily,
        homeDirectoryURL: URL,
        appURL: URL?,
        dataRootURL: URL?,
        profiles: [InstalledBrowserProfile],
        detectionSignals: [String],
        detectionScore: Int
    ) {
        self.descriptor = descriptor
        self.resolvedFamily = resolvedFamily
        self.homeDirectoryURL = homeDirectoryURL
        self.appURL = appURL
        self.dataRootURL = dataRootURL
        self.profiles = profiles
        self.detectionSignals = detectionSignals
        self.detectionScore = detectionScore
    }
}
