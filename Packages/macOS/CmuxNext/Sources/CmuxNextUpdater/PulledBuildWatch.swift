import CmuxUpdater
public import Foundation
import Observation

/// One entry of the feed's `pulled.json`, written by `nightly-next-rollback.yml` next to the
/// appcast (`scripts/ci/nightly_next_feed_rollback.py pulled`): a build taken off the feed, why,
/// and the build the feed serves instead.
nonisolated public struct PulledBuild: Equatable, Sendable, Decodable {
    public var build: String
    public var reason: String
    public var pulledAt: String?
    public var serve: String?

    public init(build: String, reason: String, pulledAt: String? = nil, serve: String? = nil) {
        self.build = build
        self.reason = reason
        self.pulledAt = pulledAt
        self.serve = serve
    }

    /// The entries of a `pulled.json` body; an unreadable body or entry is skipped, never fatal.
    public static func decode(_ data: Data) -> [PulledBuild] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return items.compactMap { item in
            guard let entry = item as? [String: Any], let build = entry["build"] as? String else { return nil }
            return PulledBuild(build: build, reason: entry["reason"] as? String ?? "",
                               pulledAt: entry["pulledAt"] as? String, serve: entry["serve"] as? String)
        }
    }

    /// Where the pulled list for `feedURL` lives: next to the appcast. The legacy NIGHTLY feed
    /// (`/nightly-next/appcast-arm64.xml`) republishes the cmux NEXT builds under the same build
    /// numbers, and only the cmux NEXT feed (`/nightly-next/next/`) is pulled, so a legacy app
    /// also reads `/nightly-next/next/pulled.json`.
    public static func listURLs(feedURL: String) -> [URL] {
        guard let feed = URL(string: feedURL), feed.scheme == "https" else { return [] }
        let folder = feed.deletingLastPathComponent()
        var urls = [folder.appending(path: "pulled.json")]
        if folder.path.hasSuffix("/nightly-next") || folder.path.hasSuffix("/nightly-next/") {
            urls.append(folder.appending(path: "next/pulled.json"))
        }
        return urls
    }
}

/// The feed's pulled list (nightly train, section 2), read at launch and after every Sparkle update
/// cycle (scheduled, launch, wake, or asked for); nothing polls. A pulled build never shows a banner
/// or a rollback choice (Leo 2026-10-29: "why the fuck am I even getting a thing that I can download
/// that I can just— that was pulled in the first place? Just fucking cancel it"): the updater drops
/// a staged pulled build and gets the newest good one, and a running pulled build updates to the
/// newest good one (``UpdaterService/followPulled()``).
@MainActor
@Observable
public final class PulledBuildWatch {
    /// The running build's entry on the pulled list, or nil.
    public private(set) var pulled: PulledBuild?
    /// Every build seen on the pulled list since launch: the Updated card leaves them out when it counts the newer
    /// builds ("2 builds behind newest"), and the updater never installs one.
    public private(set) var pulledBuilds: [String] = []
    /// The daemons' state roots for the rollback's store check (set by the App).
    @ObservationIgnored public var stateDirectories: () -> [URL?] = { [nil] }
    /// Runs after every read of the list (set by the updater).
    @ObservationIgnored var onRefresh: @MainActor () -> Void = {}
    @ObservationIgnored let build: String
    @ObservationIgnored let feedURL: () -> String
    /// Reads one list (replaced by tests).
    @ObservationIgnored var fetch: @Sendable (URL) async -> Data?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(build: String, feedURL: @escaping () -> String,
         fetch: @escaping @Sendable (URL) async -> Data? = PulledBuildWatch.download) {
        self.build = build
        self.feedURL = feedURL
        self.fetch = fetch
    }

    /// The watch for `updater`'s running build and feed (the test feed while one is in use).
    /// The closure holds the updater weakly: it owns this watch.
    convenience init(updater: UpdaterService) {
        self.init(build: updater.identity.build,
                  feedURL: { [weak updater] in
                      guard let updater else { return "" }
                      return updater.testFeedURL ?? updater.identity.feed().url
                  })
    }

    /// Reads the pulled list at launch and after every update cycle `controller` finishes.
    @discardableResult
    func start(controller: UpdateController?) -> Task<Void, Never> {
        controller?.onUpdateCycleFinished = { [weak self] in self?.refresh() }
        return refresh()
    }

    /// Reads the pulled list now (joins a read in flight).
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        let urls = PulledBuild.listURLs(feedURL: feedURL()), fetch = fetch, build = build
        let task = Task { [weak self] in
            // Every list at once, so a read waits one request's time (a legacy feed has two).
            let lists = await withTaskGroup(of: (Int, Data?).self) { group in
                for (index, url) in urls.enumerated() { group.addTask { (index, await fetch(url)) } }
                var lists = [Data?](repeating: nil, count: urls.count)
                for await (index, data) in group { lists[index] = data }
                return lists
            }
            let read = lists.compactMap { $0 }.flatMap(PulledBuild.decode)
            guard let self else { return }
            self.refreshTask = nil
            // A pulled build stays pulled for the life of this process: a read that fails, in whole
            // or for one of its lists, never forgets one (the feed never un-pulls a build).
            var all = self.pulledBuilds
            for entry in read where !all.contains(entry.build) { all.append(entry.build) }
            if self.pulledBuilds != all { self.pulledBuilds = all }
            if self.pulled == nil, let entry = read.first(where: { $0.build == build }) { self.pulled = entry }
            self.onRefresh()
        }
        refreshTask = task
        return task
    }

    /// Whether `build` is on the pulled list as last read.
    func isPulled(_ build: String) -> Bool {
        pulledBuilds.contains(build)
    }

    /// `pulled.json` over HTTPS, never from a cache; nil on any failure (a missing list is the
    /// normal case: nothing was ever pulled).
    nonisolated static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
