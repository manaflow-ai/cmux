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

    private nonisolated final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public init(deadline: TimeInterval = 15, followsRedirects: Bool = true) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = deadline
        configuration.timeoutIntervalForResource = deadline
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.init(configuration: configuration, followsRedirects: followsRedirects)
    }

    /// Tests exercise redirects through URLSession with a deterministic protocol.
    init(configuration: URLSessionConfiguration, followsRedirects: Bool) {
        session = URLSession(configuration: configuration,
                             delegate: followsRedirects ? nil : RedirectRejectingDelegate(), delegateQueue: nil)
    }

    public func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppcastParseError(message: "feed returned HTTP \(http.statusCode)")
        }
        return data
    }
}

/// The ordering of two source commits on feat-cmux-next.
nonisolated public enum SourceCommitRelation: Sendable, Equatable {
    case older
    case equal
    case newer
    case unknown
}

/// Compares source commits without treating build or publication time as source order.
nonisolated public protocol SourceCommitComparing: Sendable {
    func compare(_ lhs: String, _ rhs: String) async -> SourceCommitRelation
}

/// Uses GitHub's ancestry-aware compare endpoint. Failures are fail-closed so a
/// temporary network error cannot make an app downgrade.
nonisolated public struct GitHubSourceCommitComparator: SourceCommitComparing {
    private let session: URLSession

    public init(deadline: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = deadline
        configuration.timeoutIntervalForResource = deadline
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func compare(_ lhs: String, _ rhs: String) async -> SourceCommitRelation {
        guard let lhs = UpdateBuildIdentity.normalizedCommit(lhs),
              let rhs = UpdateBuildIdentity.normalizedCommit(rhs) else { return .unknown }
        guard lhs != rhs else { return .equal }
        guard let url = URL(string: "https://api.github.com/repos/manaflow-ai/cmux/compare/\(lhs)...\(rhs)") else { return .unknown }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("cmux-next-updater", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return .unknown }
            switch try JSONDecoder().decode(CompareResponse.self, from: data).status {
            case "ahead": return .older
            case "behind": return .newer
            case "identical": return .equal
            default: return .unknown
            }
        } catch {
            return .unknown
        }
    }

    private struct CompareResponse: Decodable { let status: String }
}

/// Read-only update check: fetches the build's feed and reports what Sparkle
/// would offer this Mac. Used by tagged DEV builds (where Sparkle never runs)
/// and by `updates.check` on every build. It cannot install anything.
nonisolated public struct UpdateProber: Sendable {
    private let fetcher: any AppcastFetching
    private let architecture: UpdateHostArchitecture
    private let sourceComparator: any SourceCommitComparing

    public init(fetcher: any AppcastFetching = URLSessionAppcastFetcher(), architecture: UpdateHostArchitecture = .current,
                sourceComparator: (any SourceCommitComparing)? = nil) {
        self.fetcher = fetcher
        self.architecture = architecture
        self.sourceComparator = sourceComparator ?? GitHubSourceCommitComparator()
    }

    /// Off the main actor: the feed's items an updater allowing `allowedChannels` sees, in feed
    /// order (a ring switch looks for the ring's builds this Mac kept, ``RingReturn``).
    @concurrent
    public func offered(_ identity: UpdateBuildIdentity, allowedChannels: Set<String>) async throws -> [AppcastItem] {
        let feed = identity.feed(architecture: architecture)
        guard let url = URL(string: feed.url) else { throw AppcastParseError(message: "invalid feed URL \(feed.url)") }
        return try AppcastParser.parse(try await fetcher.fetch(url)).filter { $0.isOffered(allowing: allowedChannels) }
    }

    /// Off the main actor: network and XML parsing. Items whose `sparkle:channel` is not in
    /// `allowedChannels` are skipped, as Sparkle's `allowedChannels(for:)` skips them; nil
    /// allows what the feed's own channel allows on the default ring.
    @concurrent
    public func probe(_ identity: UpdateBuildIdentity, allowedChannels: Set<String>? = nil, system: SystemVersion = .current,
                      now: Date = Date()) async throws -> UpdateProbeResult {
        let feed = identity.feed(architecture: architecture)
        guard let url = URL(string: feed.url) else { throw AppcastParseError(message: "invalid feed URL \(feed.url)") }
        let allowed = allowedChannels ?? feed.channel.allowedSparkleChannels
        let items = try AppcastParser.parse(try await fetcher.fetch(url)).filter { $0.isOffered(allowing: allowed) }
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

    /// Probes both cmux NEXT feeds and chooses the feed whose latest compatible item
    /// names the newer feat-cmux-next source commit. Unknown ancestry keeps the running
    /// channel, so a temporary GitHub failure can never make an app downgrade.
    @concurrent
    public func probeCrossChannel(_ identity: UpdateBuildIdentity, allowedChannels: Set<String>? = nil,
                                  system: SystemVersion = .current, now: Date = Date()) async throws -> UpdateProbeResult {
        let feed = identity.feed(architecture: architecture)
        guard feed.channel == .nightlyNext, let counterpartURL = identity.counterpartFeed(architecture: architecture),
              let currentURL = URL(string: feed.url), let counterpart = URL(string: counterpartURL) else {
            return try await probe(identity, allowedChannels: allowedChannels, system: system, now: now)
        }
        let allowed = allowedChannels ?? feed.channel.allowedSparkleChannels(ring: .nightly)
        async let currentData = fetcher.fetch(currentURL)
        async let counterpartData = fetcher.fetch(counterpart)
        let currentItems = try AppcastParser.parse(try await currentData).filter { $0.isOffered(allowing: allowed) }
        let counterpartItems = try AppcastParser.parse(try await counterpartData).filter { $0.isOffered(allowing: allowed) }
        let currentLatest = latestCompatible(currentItems, system: system)
        let counterpartLatest = latestCompatible(counterpartItems, system: system)
        let selected: (url: String, items: [AppcastItem])
        if let currentLatest, let counterpartLatest,
           let currentCommit = currentLatest.sourceCommit, let counterpartCommit = counterpartLatest.sourceCommit {
            switch await sourceComparator.compare(currentCommit, counterpartCommit) {
            case .older: selected = (counterpartURL, counterpartItems)
            case .equal, .newer, .unknown: selected = (feed.url, currentItems)
            }
        } else {
            selected = (feed.url, currentItems)
        }
        return UpdateProbeResult(
            track: identity.track,
            feedURL: selected.url,
            currentVersion: identity.shortVersion,
            currentBuild: identity.build,
            system: system,
            itemCount: selected.items.count,
            outcome: AppcastSelector.select(from: selected.items, currentBuild: identity.build, system: system),
            checkedAt: now
        )
    }

    private func latestCompatible(_ items: [AppcastItem], system: SystemVersion) -> AppcastItem? {
        items.filter { $0.supports(system) }.max { AppcastSelector.isOlder($0.version, than: $1.version) }
    }
}
