public import CmuxUpdater
public import Foundation

/// Downloads an appcast. A seam so tests serve fixture feeds.
nonisolated public protocol AppcastFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

/// Fetches over an ephemeral `URLSession` with a hard deadline and no cache,
/// so a probe always sees the live feed and never hangs.
nonisolated public struct URLSessionAppcastFetcher: AppcastFetching {
    private let session: URLSession

    public init(deadline: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = deadline
        configuration.timeoutIntervalForResource = deadline
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppcastParseError(message: "feed returned HTTP \(http.statusCode)")
        }
        return data
    }
}

/// Read-only update check: fetches the build's feed and reports what Sparkle
/// would offer this Mac. Used by tagged DEV builds (where Sparkle never runs)
/// and by `updates.check` on every build. It cannot install anything.
nonisolated public struct UpdateProber: Sendable {
    private let fetcher: any AppcastFetching
    private let architecture: UpdateHostArchitecture

    public init(fetcher: any AppcastFetching = URLSessionAppcastFetcher(), architecture: UpdateHostArchitecture = .current) {
        self.fetcher = fetcher
        self.architecture = architecture
    }

    /// Off the main actor: network and XML parsing.
    @concurrent
    public func probe(_ identity: UpdateBuildIdentity, system: SystemVersion = .current, now: Date = Date()) async throws -> UpdateProbeResult {
        let feed = identity.feed(architecture: architecture)
        guard let url = URL(string: feed.url) else { throw AppcastParseError(message: "invalid feed URL \(feed.url)") }
        let items = try AppcastParser.parse(try await fetcher.fetch(url))
        return UpdateProbeResult(
            track: identity.track,
            feedURL: feed.url,
            currentVersion: identity.shortVersion,
            currentBuild: identity.build,
            system: system,
            itemCount: items.count,
            outcome: AppcastSelector.select(from: items, currentBuild: identity.build, system: system),
            checkedAt: now
        )
    }
}
