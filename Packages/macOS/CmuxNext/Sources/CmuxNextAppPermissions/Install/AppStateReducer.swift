/// One user's app states as the owner holds them, the receipts that make
/// every op idempotent, and the default installs already offered.
public nonisolated struct AppStateStore: Sendable, Hashable, Codable {
    public var apps: [String: AppInstallState]
    /// `<client>\u{1F}<idempotency key>` -> the accepted op and its commit.
    /// Keys are scoped by client, so two clients never collide. The owner
    /// prunes receipts older than its replay window; the model keeps them all.
    public var receipts: [String: AppStateReceipt]
    /// Apps the first-launch bootstrap has offered as default installs.
    /// Kept forever (never pruned): a default app is offered once, so a
    /// removal sticks whatever happens to it later.
    public var defaultsOffered: Set<String>

    public init(apps: [String: AppInstallState] = [:], receipts: [String: AppStateReceipt] = [:], defaultsOffered: Set<String> = []) {
        self.apps = apps
        self.receipts = receipts
        self.defaultsOffered = defaultsOffered
    }

    public func state(_ app: String) -> AppInstallState { apps[app] ?? .notInstalled(app) }

    /// The receipt key of `key` sent by `client`.
    public static func receiptKey(client: String, key: String) -> String { "\(client)\u{1F}\(key)" }

    enum CodingKeys: String, CodingKey {
        case apps, receipts
        case defaultsOffered = "defaults_offered"
    }
}

/// The pure reducer `(store, op, actor) -> Result<(store', commit), reject>`,
/// the reference the owners port 1:1 (app-hide.md section 3 lists the
/// invariants and the tests that check them).
public nonisolated enum AppStateReducer {
    public static func apply(_ op: AppStateOp, to store: AppStateStore,
                             actor: AppStateActor) -> Result<(AppStateStore, AppStateCommit), AppStateReject> {
        if op.key.hasPrefix(AppDefaultInstalls.keyPrefix), actor.origin != .system { return .failure(.reservedKey) }
        let receiptKey = AppStateStore.receiptKey(client: actor.client, key: op.key)
        if let receipt = store.receipts[receiptKey] {
            guard receipt.op == op else { return .failure(.keyReused) }
            return .success((store, AppStateCommit(outcome: .replayed, events: [])))
        }
        if let reject = originReject(op.kind, actor: actor) { return .failure(reject) }
        var result = store
        let old = store.state(op.app)
        var next = old
        var outcome = AppStateCommit.Outcome.applied
        var extra: [AppStateEvent] = []

        switch op.kind {
        case .install(let source):
            if source == .team, !actor.teamAdmin { return .failure(.sourceNotAllowed(.team)) }
            if source == .default {
                // Offered once per user, ever: a later removal sticks.
                guard result.defaultsOffered.insert(op.app).inserted else { break }
            }
            guard !old.installed else { break }
            next.source = source
            next.enabled = true
            next.hidden = false
            next.hiddenAccess = .all
        case .remove(let confirmed):
            guard let source = old.source else { return .failure(.notInstalled) }
            if source == .team, !actor.teamAdmin { return .failure(.adminOnly) }
            if source == .default, !confirmed {
                next.hidden = true
                outcome = .convertedToHide
                break
            }
            next.source = nil
            next.enabled = false
            next.hidden = false
            next.hiddenAccess = .all
            extra = [.storageRemoved(app: op.app), .grantRemoved(app: op.app)]
        case .enable, .disable, .hide, .unhide, .setHiddenAccess:
            guard old.installed else { return .failure(.notInstalled) }
            switch op.kind {
            case .enable: next.enabled = true
            case .disable: next.enabled = false
            case .hide: next.hidden = true
            case .unhide: next.hidden = false
            case .setHiddenAccess(let cli, let mcp, let automations):
                next.hiddenAccess = AppHiddenAccess(cli: cli ?? old.hiddenAccess.cli, mcp: mcp ?? old.hiddenAccess.mcp,
                                                    automations: automations ?? old.hiddenAccess.automations)
            default: break
            }
        }

        let changed = next != old
        if changed {
            next.revision = old.revision + 1
            result.apps[op.app] = next
        } else if outcome == .applied {
            outcome = .noChange
        }
        let commit = AppStateCommit(outcome: outcome, events: changed ? [.changed(next)] + extra : [])
        result.receipts[receiptKey] = AppStateReceipt(op: op, commit: commit)
        return .success((result, commit))
    }

    /// Channel rules: installs and hidden access are user only (default
    /// installs come from the owner itself); the rest is user or CLI;
    /// MCP, scripts (automations) and remote relays never change app state.
    static func originReject(_ kind: AppStateOp.Kind, actor: AppStateActor) -> AppStateReject? {
        let allowed: Set<AppStateOrigin> = switch kind {
        case .install(.default): [.system]
        case .install: [.user]
        case .setHiddenAccess: [.user]
        case .remove, .enable, .disable, .hide, .unhide: [.user, .cli]
        }
        return allowed.contains(actor.origin) ? nil : .originNotAllowed(actor.origin)
    }
}
