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

/// The pulled-build banner (nightly train, section 2): when the running build is on the feed's
/// pulled list, the update notice card says so and offers two choices: "Wait for the Fix"
/// (the default: the fix-forward build installs through the normal background update) and
/// "Roll Back" to the build this Mac kept (``UpdateDropBack/failure(to:stateDirectories:)``),
/// shown only when that rollback would run and asked about first (``confirmRollBack``). The list
/// is read at launch and after every Sparkle update cycle (scheduled, launch, wake, or asked for);
/// nothing polls.
@MainActor
@Observable
public final class PulledBuildWatch {
    /// The running build's entry on the pulled list, or nil.
    public private(set) var pulled: PulledBuild?
    /// The kept build a rollback would go to, or nil (none kept, or it cannot read the stores).
    public private(set) var rollbackTarget: KeptVersion?
    /// Every build on the pulled list: the Updated card leaves them out when it counts the newer
    /// builds ("2 builds behind newest"), since no Mac is offered them.
    public private(set) var pulledBuilds: [String] = []
    /// The build whose banner the person answered "Wait for the Fix" (kept in defaults).
    public private(set) var waitingBuild: String?
    /// A rollback that failed: its reason replaces the detail line.
    public private(set) var rollbackFailure: String?
    /// The daemons' state roots for the rollback's store check (set by the App).
    @ObservationIgnored public var stateDirectories: () -> [URL?] = { [nil] }
    /// Asks the person before Roll Back quits into the kept build (set by the App: the registry's
    /// confirmation presenter for `updates.rollback`, the same question as the palette and menu).
    /// Calls `proceed` only when confirmed; the default has nobody to ask, so nothing runs.
    @ObservationIgnored public var confirmRollBack: @MainActor (_ proceed: @escaping @MainActor () -> Void) -> Void = { _ in }
    @ObservationIgnored let build: String
    @ObservationIgnored let feedURL: () -> String
    @ObservationIgnored let fetch: @Sendable (URL) async -> Data?
    @ObservationIgnored let rollbackCheck: @MainActor (_ stateDirectories: [URL?]) async -> KeptVersion?
    @ObservationIgnored let rollBack: @MainActor (_ build: String, _ stateDirectories: [URL?]) async -> String?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The rollback check ran for the current pulled build.
    @ObservationIgnored private var rollbackChecked = false
    /// A rollback is running: another Roll Back press is ignored.
    @ObservationIgnored private var rollingBack = false

    static let waitingKey = "cmux.next.updates.pulledBuildWaiting"

    init(build: String, defaults: UserDefaults, feedURL: @escaping () -> String,
         fetch: @escaping @Sendable (URL) async -> Data? = PulledBuildWatch.download,
         rollbackCheck: @escaping @MainActor (_ stateDirectories: [URL?]) async -> KeptVersion?,
         rollBack: @escaping @MainActor (_ build: String, _ stateDirectories: [URL?]) async -> String?) {
        self.build = build
        self.defaults = defaults
        self.feedURL = feedURL
        self.fetch = fetch
        self.rollbackCheck = rollbackCheck
        self.rollBack = rollBack
        waitingBuild = defaults.string(forKey: Self.waitingKey)
    }

    /// The watch for `updater`'s running build and feed (the test feed while one is in use).
    /// The closures hold the updater weakly: it owns this watch.
    convenience init(updater: UpdaterService) {
        self.init(build: updater.identity.build, defaults: updater.defaults,
                  feedURL: { [weak updater] in
                      guard let updater else { return "" }
                      return updater.testFeedURL ?? updater.identity.feed().url
                  },
                  rollbackCheck: { [weak updater] directories in
                      guard let updater else { return nil }
                      return try? await UpdateDropBack(updater).run(checkOnly: true, stateDirectories: directories)
                  },
                  rollBack: { [weak updater] build, directories in
                      guard let updater else { return nil }
                      return await UpdateDropBack(updater).failure(to: build, stateDirectories: directories)
                  })
    }

    /// Reads the pulled list at launch and after every update cycle `controller` finishes.
    func start(controller: UpdateController?) {
        controller?.onUpdateCycleFinished = { [weak self] in self?.refresh() }
        refresh()
    }

    /// Reads the pulled list now (joins a read in flight).
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        let urls = PulledBuild.listURLs(feedURL: feedURL()), fetch = fetch, build = build
        let task = Task { [weak self] in
            var entry: PulledBuild?
            var all: [String] = []
            for url in urls {
                guard let data = await fetch(url) else { continue }
                let list = PulledBuild.decode(data)
                all += list.map(\.build).filter { !all.contains($0) }
                if entry == nil, let found = list.first(where: { $0.build == build }) { entry = found }
            }
            if self?.pulledBuilds != all { self?.pulledBuilds = all }
            await self?.apply(entry)
            self?.refreshTask = nil
        }
        refreshTask = task
        return task
    }

    private func apply(_ entry: PulledBuild?) async {
        guard let entry else {
            pulled = nil
            rollbackTarget = nil
            rollbackChecked = false
            rollbackFailure = nil
            return
        }
        // The check verifies the app's signature, so it runs once per pulled build, not every cycle.
        if pulled?.build != entry.build || !rollbackChecked {
            rollbackTarget = await rollbackCheck(stateDirectories())
            rollbackChecked = true
        }
        pulled = entry
    }

    /// The notice card while the running build is pulled and the person has not chosen to wait.
    public var card: UpdateCard? {
        guard let pulled, waitingBuild != pulled.build else { return nil }
        return .pulled(reason: rollbackFailure ?? pulled.reason, rollbackVersion: rollbackTarget?.shortVersion)
    }

    /// A banner button (or its x, which is "Wait for the Fix").
    public func perform(_ action: UpdateCardAction) {
        guard let pulled else { return }
        switch action {
        case .rollBack:
            guard let target = rollbackTarget, !rollingBack else { return }
            // Destructive (it quits and relaunches): asks first; Cancel leaves the banner as it was.
            confirmRollBack { [weak self] in self?.startRollBack(to: target) }
        case .waitForFix:
            waitingBuild = pulled.build
            defaults.set(pulled.build, forKey: Self.waitingKey)
        case .update, .releaseNotes, .retry, .details:
            break
        }
    }

    /// Runs the confirmed rollback to `target`; a second confirmed press while one runs is ignored.
    private func startRollBack(to target: KeptVersion) {
        guard !rollingBack else { return }
        rollbackFailure = nil
        rollingBack = true
        let directories = stateDirectories(), rollBack = rollBack
        Task { [weak self] in
            // Success relaunches into the kept build; only a failure comes back.
            let failure = await rollBack(target.build, directories)
            self?.rollingBack = false
            if let failure { self?.rollbackFailure = failure }
        }
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
