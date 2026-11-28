import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Synchronization

/// What every diff tab shares: the per-user session root, the sidecar pool
/// (4 children at once, nil when this build has no bundled sidecar) and the
/// language pack feed. Each tab still gets its own grant from ``prepare``.
final class DiffPageRuntime {
    let root: URL
    let sidecar: (any DiffSidecarRunning)?
    let languages: DiffLanguageFeed
    /// Reads the session host's `git.status` of a folder.
    private let status: @MainActor (String) async throws -> JSONValue
    nonisolated private static let swept = Mutex(false)
    nonisolated private static let live = Mutex<[ObjectIdentifier: DiffSessionGrant]>([:])

    init(root: URL = DiffSessionRoot.url(), sidecar: (any DiffSidecarRunning)?? = nil,
         configFile: URL = CmuxConfigFile.defaultURL(),
         status: (@MainActor (String) async throws -> JSONValue)? = nil) {
        self.root = root
        self.sidecar = sidecar ?? DiffSidecarLauncher.bundled(root: root).map { DiffSidecarPool(runner: $0) }
        languages = DiffLanguageFeed(directory: DiffLanguagePack.directory(configFile: configFile))
        self.status = status ?? { _ in throw DiffTabFailure(title: "", message: DiffPageStrings.notRepository) }
    }

    /// The runtime of the running app: `git.status` through the agent pane's
    /// git link (its own daemon connection, so a slow read never holds
    /// terminal commands).
    convenience init(git: AgentPaneGitLink) {
        self.init(status: { directory in
            let data = try await git.read(.status(cwd: directory))
            return try JSONValue.parse(data)
        })
    }

    /// The repository `folder` is in, from the session host's `git.status`;
    /// nil when it is in none (or the session host cannot say).
    func repository(at folder: URL) async -> DiffRepository? {
        guard let status = try? await status(folder.path) else { return nil }
        return DiffRepository(status: status)
    }

    /// The tab's grant (for `repository`'s root) and config. Fails with a
    /// ``DiffTabFailure`` the page shows.
    func prepare(repository: DiffRepository, source: DiffOpenSource) -> Task<DiffTabReady, any Error> {
        let root = root, available = sidecar != nil
        return Task {
            guard available else { throw DiffTabFailure(title: repository.name, message: DiffPageStrings.unavailable) }
            let grant = try await Self.grant(root: root, repository: repository.root)
            if Task.isCancelled {
                await Self.drop(grant)
                throw CancellationError()
            }
            return DiffTabReady(grant: grant, config: DiffPageConfig.make(repository: repository, source: source, token: grant.token))
        }
    }

    @concurrent private static func grant(root wanted: URL, repository: String) async throws -> DiffSessionGrant {
        let root: URL
        do {
            root = try DiffSessionRoot.prepare(wanted)
        } catch {
            throw DiffTabFailure(title: URL(fileURLWithPath: repository).lastPathComponent, message: DiffPageStrings.unavailable)
        }
        let sweep = swept.withLock { swept -> Bool in
            defer { swept = true }
            return !swept
        }
        if sweep { DiffSessionRoot.sweep(root) }
        let grant = try DiffSessionGrant.create(root: root, repository: repository)
        live.withLock { $0[ObjectIdentifier(grant)] = grant }
        return grant
    }

    @concurrent static func drop(_ grant: DiffSessionGrant) async {
        live.withLock { $0[ObjectIdentifier(grant)] = nil }
        grant.remove()
    }

    /// App quit: removes every live grant now, on the calling thread (the
    /// process is ending; nothing else will).
    static func removeAllGrantsNow() {
        let grants = live.withLock { live -> [DiffSessionGrant] in
            defer { live.removeAll() }
            return Array(live.values)
        }
        for grant in grants { grant.remove() }
    }
}
