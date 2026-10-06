public import Foundation

/// The REPL sessions' domain policies as the navigation checks read them,
/// and whether each session's content rules are on its tabs.
///
/// A policy setter (`session.prohibitedDomains` and the like) returns once
/// the native session holds the policy, before WebKit compiles its content
/// rules. The board takes the policy at once (``publish(_:sessionID:)``,
/// from any thread), so the next navigation or popup the checks judge
/// already uses it. Until the rules that match the latest policy are on the
/// session's tabs (``rulesInstalled(sessionID:generation:)``), its tabs'
/// navigations wait (``whenRulesSettle(sessionID:_:)``): a page loaded then
/// would load its subresources under the previous rules. When WebKit
/// refuses the rules (``rulesFailed(sessionID:generation:reason:)``), the
/// policy is not in force for subresources, and the waiting navigations
/// learn it, to refuse.
public final class BrowserReplPolicyBoard: @unchecked Sendable {
    public enum RuleState: Equatable, Sendable {
        /// The rules of the latest policy are on the tabs, or the session
        /// has no policy.
        case installed
        /// WebKit is compiling the rules of the latest policy.
        case pending
        /// WebKit refused the rules of the latest policy.
        case failed(String)
    }

    private struct Entry {
        var policy: BrowserReplDomainPolicy
        var generation: Int
        var state: RuleState
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Navigations waiting for a session's rules, run on the main actor.
    private var waiters: [String: [@MainActor (RuleState) -> Void]] = [:]
    private var nextGeneration = 0
    /// Each session's working and temporary directories, the only ones its
    /// tabs load local files from.
    private var fileRoots: [String: [String]] = [:]
    /// The same directories with the identity each had when the session
    /// named it (``BrowserReplFileRoot``), which a file load requires.
    private var pinnedFileRoots: [String: [BrowserReplFileRoot]] = [:]

    public init() {}

    /// Makes `policy` the session's policy now; its rules are pending until
    /// the call that compiles them reports this generation.
    @discardableResult
    public func publish(_ policy: BrowserReplDomainPolicy, sessionID: String) -> Int {
        lock.withLock {
            nextGeneration += 1
            entries[sessionID] = Entry(policy: policy, generation: nextGeneration, state: .pending)
            return nextGeneration
        }
    }

    /// The session's latest policy, or nil when it has none in force.
    public func policy(for sessionID: String) -> BrowserReplDomainPolicy? {
        lock.withLock {
            guard let policy = entries[sessionID]?.policy, policy.isActive else { return nil }
            return policy
        }
    }

    /// Sets the directories the session's tabs may load local files from;
    /// the navigation checks read them at once.
    public func setFileRoots(_ roots: [String], sessionID: String) {
        let pinned = roots.map(BrowserReplFileRoot.init(path:))
        lock.withLock {
            fileRoots[sessionID] = roots
            pinnedFileRoots[sessionID] = pinned
        }
    }

    /// The session's directories, or nil when it set none.
    public func fileRoots(for sessionID: String) -> [String]? {
        lock.withLock { fileRoots[sessionID] }
    }

    /// The session whose directories govern a load of the local file `url`
    /// in a tab whose live creator is `creator` and to which `attached`
    /// sessions are attached, or nil.
    /// The tab's creator governs every file its tab loads; in a user's tab,
    /// an attached session governs a file that lies, as written, inside its
    /// directories (it may have put a link there); any other file is the
    /// user's own load.
    public func fileLoadSession(_ url: URL, creator: String?, attached: [String]) -> String? {
        guard url.isFileURL else { return nil }
        if let creator { return creator }
        let path = url.path(percentEncoded: false)
        return attached.sorted().first { sessionID in
            BrowserReplFileSandbox.isLexicallyInside(path, roots: fileRoots(for: sessionID) ?? [])
        }
    }

    /// Runs `load`, which must start the browser's load of the file `url`,
    /// with the read access the governing session `sessionID` grants.
    /// Checked and granted while no REPL `fs.rename` can run
    /// (``BrowserReplFileSandbox/withPinnedFileAccess(_:roots:_:)``): the
    /// grant is the session root that holds the file, never the file's
    /// parent directory as a link swapped in would resolve it.
    /// - Throws: `blocked` when the session has no directories, the file is
    ///   outside them or a link lies below them, or a root was replaced.
    public func withPinnedFileAccess<T>(_ url: String, sessionID: String, _ load: (URL) throws -> T) throws -> T {
        let roots = lock.withLock { pinnedFileRoots[sessionID] ?? [] }
        return try BrowserReplFileSandbox.withPinnedFileAccess(url, roots: roots, load)
    }

    public func ruleState(for sessionID: String) -> RuleState {
        lock.withLock { entries[sessionID]?.state ?? .installed }
    }

    /// Runs `body` once the session's rules are no longer pending: now, or
    /// when the latest policy's rules are installed or refused, or the
    /// session ends.
    @MainActor
    public func whenRulesSettle(sessionID: String, _ body: @escaping @MainActor (RuleState) -> Void) {
        let state: RuleState? = lock.withLock {
            let state = entries[sessionID]?.state ?? .installed
            guard state == .pending else { return state }
            waiters[sessionID, default: []].append(body)
            return nil
        }
        if let state { body(state) }
    }

    /// The rules of the policy published as `generation` are on the tabs.
    /// A later policy's rules are still pending; this releases nothing then.
    @MainActor
    public func rulesInstalled(sessionID: String, generation: Int) {
        settle(sessionID: sessionID, generation: generation, state: .installed)
    }

    /// WebKit refused the rules of the policy published as `generation`.
    @MainActor
    public func rulesFailed(sessionID: String, generation: Int, reason: String) {
        settle(sessionID: sessionID, generation: generation, state: .failed(reason))
    }

    /// The session ended: its tabs are no longer its, and nothing waits.
    @MainActor
    public func removeSession(_ sessionID: String) {
        let released = lock.withLock {
            entries.removeValue(forKey: sessionID)
            fileRoots.removeValue(forKey: sessionID)
            pinnedFileRoots.removeValue(forKey: sessionID)
            return waiters.removeValue(forKey: sessionID) ?? []
        }
        for body in released { body(.installed) }
    }

    @MainActor
    private func settle(sessionID: String, generation: Int, state: RuleState) {
        let released: [@MainActor (RuleState) -> Void] = lock.withLock {
            guard var entry = entries[sessionID], entry.generation == generation else { return [] }
            entry.state = state
            entries[sessionID] = entry
            return waiters.removeValue(forKey: sessionID) ?? []
        }
        for body in released { body(state) }
    }
}
