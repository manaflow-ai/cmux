public import CmuxNextAgentPane
import CmuxNextSettings
public import Foundation

/// A diff the runtime computed before any tab asked for it: an agent's turn ended in the repository,
/// so the next thing the person may do is look at what it changed. Its grant, the config a tab of the
/// repository would get, the sidecar's `sessionOpened` answer, and the scope's fingerprint read just
/// before the open (the page's freshness baseline: a change after it reconciles the shown diff).
nonisolated struct DiffWarmEntry: Sendable {
    let repository: DiffRepository
    let grant: DiffSessionGrant
    let config: JSONValue
    let session: DiffWarmSession
}

/// A precomputed session a tab starts on (``DiffTabReady/warm``).
public nonisolated struct DiffWarmSession: Sendable {
    let result: JSONValue
    let fingerprint: String?
}

/// Precompute (Leo, 2026-11-05: "There's no reason for them to have a delay, even under load."): when
/// an agent's turn ends, the runtime opens the turn's repository's default diff in the background, so a
/// diff tab opened after it starts with its session already open and its patch on disk, as Chrome's
/// prerender loads a page the person is likely to open next. The work is invisible, so it is throttled
/// as Chrome throttles background work: one sidecar child at a time on its own pool (a person's open
/// never waits behind it), utility priority, one run per repository in flight (a later turn end runs
/// once more after it), and at most ``warmLimit`` repositories kept.
extension DiffPageRuntime {
    /// Repositories with a precomputed diff kept at once (the oldest goes first).
    static let warmLimit = 4

    /// Precomputes the default diff of the repository `folder` is in, read through `git` (the session
    /// host's `git.status` for the repository, `git.diff` for the fingerprint).
    public func warm(folder: URL, git: any DiffGitRunning) {
        guard warmSidecar != nil, !isRemote, !git.isRemote else { return }
        let key = folder.standardizedFileURL.path
        guard warming[key] == nil else {
            rewarm.insert(key)
            return
        }
        // task-owner: one background precompute of the folder's diff; the runtime keeps at most one per folder
        warming[key] = Task(priority: .utility) { [weak self] in
            await self?.computeWarm(folder: folder, git: git)
            guard let self else { return }
            warming[key] = nil
            if rewarm.remove(key) != nil { warm(folder: folder, git: git) }
        }
    }

    /// Waits for the precomputes in flight (tests).
    func warmed() async {
        while let next = warming.values.first { await next.value }
    }

    private func computeWarm(folder: URL, git: any DiffGitRunning) async {
        guard let sidecar = warmSidecar, let status = try? await git.status(folder.path),
              let repository = DiffRepository(status: status),
              let grant = try? await Self.grant(root: root, repository: repository.root) else { return }
        let config = DiffPageConfig.make(repository: repository, source: .default, token: grant.token)
        guard let source = config["payload"]?["sessionSource"] else {
            await Self.drop(grant)
            return
        }
        // Read before the open: an edit between the two makes the page reconcile once, never miss it.
        // With no fingerprint the page could not tell an old diff from a current one: keep none.
        guard let fingerprint = await Self.fingerprint(of: source, in: repository.root, git: git) else {
            await Self.drop(grant)
            return
        }
        let params: [String: JSONValue] = ["source": source, "capabilityToken": .string(grant.token),
                                           "sessionId": .string(UUID().uuidString.lowercased())]
        guard let result = try? await DiffPageProvider.request(sidecar, "sessionOpen", params: params),
              DiffPageProvider.openedSession(result) != nil else {
            await Self.drop(grant)
            return
        }
        let entry = DiffWarmEntry(repository: repository, grant: grant, config: config,
                                  session: DiffWarmSession(result: result, fingerprint: fingerprint))
        if let old = warmedEntries.removeValue(forKey: repository.root) { await Self.drop(old.grant) }
        warmedEntries[repository.root] = entry
        warmOrder.removeAll { $0 == repository.root }
        warmOrder.append(repository.root)
        while warmOrder.count > Self.warmLimit, let oldest = warmOrder.first {
            warmOrder.removeFirst()
            if let dropped = warmedEntries.removeValue(forKey: oldest) { await Self.drop(dropped.grant) }
        }
    }

    /// The precomputed diff a new tab of `repository` showing the default scope starts on, taken (a
    /// tab owns its grant), when the repository is as it was then (same branch and base). With a
    /// `turn` (the header's Changes) the config also offers Last turn; the session is the same.
    func takeWarm(_ repository: DiffRepository, source: DiffOpenSource, turn: DiffTurn?) -> DiffTabReady? {
        guard source == .default, let entry = warmedEntries.removeValue(forKey: repository.root) else { return nil }
        warmOrder.removeAll { $0 == repository.root }
        let config = DiffPageConfig.make(repository: repository, source: source, token: entry.grant.token, turn: turn)
        guard entry.repository == repository,
              config["payload"]?["sessionSource"] == entry.config["payload"]?["sessionSource"] else {
            // task-owner: drops a precomputed grant the repository has moved past; ends when its files are gone
            Task { await Self.drop(entry.grant) }
            return nil
        }
        return DiffTabReady(grant: entry.grant, config: config, turn: turn, warm: entry.session)
    }

    /// The fingerprint `cmux.diff.git.fingerprint` would answer for `source` now (freshness.ts's scope).
    static func fingerprint(of source: JSONValue, in repository: String, git: any DiffGitRunning) async -> String? {
        let scope: AgentPaneGitScope
        switch source["kind"]?.stringValue {
        case "unstaged": scope = .unstaged
        case "staged": scope = .staged
        case "branch": scope = source["baseRef"]?.stringValue == "HEAD" ? .uncommitted : .branch
        default: return nil
        }
        guard let diff = try? await git.diff(repository, scope: scope, includePatch: true) else { return nil }
        return await Self.hash(diff)
    }

    /// The hash of a whole diff, off the main thread (a big diff is megabytes of JSON).
    @concurrent private static func hash(_ diff: JSONValue) async -> String {
        DiffPageProvider.fingerprint(diff)
    }
}
