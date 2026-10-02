/// One user's app states as the owner holds them, plus the receipts that
/// make every op idempotent and the default installs the user removed.
public nonisolated struct AppStateStore: Sendable, Hashable, Codable {
    public var apps: [String: AppInstallState]
    /// Idempotency key -> the accepted op and its commit. The owner prunes
    /// receipts older than its replay window; the model keeps them all.
    public var receipts: [String: AppStateReceipt]
    /// Default installs the user removed with confirmation: first-launch
    /// bootstrap never installs them again.
    public var removedDefaults: Set<String>

    public init(apps: [String: AppInstallState] = [:], receipts: [String: AppStateReceipt] = [:], removedDefaults: Set<String> = []) {
        self.apps = apps
        self.receipts = receipts
        self.removedDefaults = removedDefaults
    }

    public func state(_ app: String) -> AppInstallState { apps[app] ?? .notInstalled(app) }
}

/// An accepted op kept for replay.
public nonisolated struct AppStateReceipt: Sendable, Hashable, Codable {
    public var op: AppStateOp
    public var commit: AppStateCommit
}

/// The pure reducer `(store, op, actor) -> Result<(store', commit), reject>`.
/// Invariants (AppInstallStatePropertyTests): hidden ⇒ installed;
/// uninstall clears enabled and hidden and emits storage and grant removal
/// in one commit; a team install is removed only by an admin; a default
/// install's unconfirmed Remove hides; hide and unhide emit only `changed`
/// (never grant, storage or layout); replaying a key has no effect.
public nonisolated enum AppStateReducer {
    public static func apply(_ op: AppStateOp, to store: AppStateStore,
                             actor: AppStateActor) -> Result<(AppStateStore, AppStateCommit), AppStateReject> {
        if let receipt = store.receipts[op.key] {
            guard receipt.op == op else { return .failure(.keyReused) }
            return .success((store, AppStateCommit(outcome: .replayed, events: [])))
        }
        if let reject = originReject(op.kind, actor: actor) { return .failure(reject) }
        let old = store.state(op.app)
        var next = old
        var outcome = AppStateCommit.Outcome.applied
        var extra: [AppStateEvent] = []
        var removedDefaults = store.removedDefaults

        switch op.kind {
        case .install(let source):
            if source == .default, actor.origin != .system { return .failure(.sourceNotAllowed(.default)) }
            if source == .team, !actor.teamAdmin { return .failure(.sourceNotAllowed(.team)) }
            if source == .default, removedDefaults.contains(op.app) { break }
            if source != .default { removedDefaults.remove(op.app) }
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
            if source == .default { removedDefaults.insert(op.app) }
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

        var result = store
        result.removedDefaults = removedDefaults
        let changed = next != old
        if changed {
            next.revision = old.revision + 1
            result.apps[op.app] = next
        } else if outcome == .applied {
            outcome = .noChange
        }
        let commit = AppStateCommit(outcome: outcome, events: changed ? [.changed(next)] + extra : [])
        result.receipts[op.key] = AppStateReceipt(op: op, commit: commit)
        return .success((result, commit))
    }

    /// Channel rules: installs and hidden access are user only (default
    /// installs come from the owner itself); the rest is user or CLI; MCP,
    /// automations and remote clients never change app state.
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
