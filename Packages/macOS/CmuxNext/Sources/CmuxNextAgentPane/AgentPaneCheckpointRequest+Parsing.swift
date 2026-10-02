import Foundation

nonisolated extension AgentPaneCheckpointRequest {
    /// Nil unless `method` is one of ``methods`` and `params` are exactly
    /// what the page's checkpoint client sends for it: an absolute `cwd`, the
    /// operation's fields with their types, and on a mutation an
    /// `idempotency_key`. A `get` names exactly one of `checkpoint_id` and
    /// `idempotency_key`.
    init?(method: String, params: [String: Any]?) {
        do {
            switch method {
            case "git.checkpoint.create":
                let fields = try AgentPanePageParams(params, allowed: [
                    "cwd", "idempotency_key", "expected_repository_id", "expected_worktree_id", "include_untracked",
                    "exclude_paths", "reason", "limits",
                ])
                let options = try AgentPaneCheckpointCreate(fields)
                self = try .create(cwd: fields.folder("cwd"), options: options, idempotencyKey: Self.envelopeKey(fields))
            case "git.checkpoint.get":
                let fields = try AgentPanePageParams(params, allowed: ["cwd", "checkpoint_id", "idempotency_key"])
                let id = try fields.text("checkpoint_id")
                let key = try fields.key("idempotency_key")
                let lookup: Lookup
                switch (id, key) {
                case (let id?, nil): lookup = .checkpointID(id)
                case (nil, let key?): lookup = .idempotencyKey(key)
                default: return nil
                }
                self = try .get(cwd: fields.folder("cwd"), lookup: lookup)
            case "git.checkpoint.list":
                let fields = try AgentPanePageParams(params, allowed: ["cwd", "cursor", "limit", "include_candidates"])
                self = try .list(
                    cwd: fields.folder("cwd"), cursor: fields.text("cursor"), limit: fields.count("limit"),
                    includeCandidates: fields.flag("include_candidates"))
            case "git.checkpoint.pin":
                let fields = try AgentPanePageParams(params, allowed: ["cwd", "checkpoint_id", "pin_id", "reason", "idempotency_key"])
                self = try .pin(
                    cwd: fields.folder("cwd"), checkpointID: fields.requiredText("checkpoint_id"),
                    pinID: fields.requiredText("pin_id"), reason: fields.requiredText("reason"),
                    idempotencyKey: Self.envelopeKey(fields))
            case "git.checkpoint.unpin":
                let fields = try AgentPanePageParams(params, allowed: ["cwd", "checkpoint_id", "pin_id", "idempotency_key"])
                self = try .unpin(
                    cwd: fields.folder("cwd"), checkpointID: fields.requiredText("checkpoint_id"),
                    pinID: fields.requiredText("pin_id"), idempotencyKey: Self.envelopeKey(fields))
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    /// A mutation's required key, which goes in the request envelope.
    private static func envelopeKey(_ fields: AgentPanePageParams) throws -> String {
        guard let key = try fields.key("idempotency_key") else { throw AgentPanePageParams.Malformed() }
        return key
    }
}

nonisolated extension AgentPaneCheckpointCreate {
    /// A create's own fields from the page's params: `include_untracked` is
    /// a list of paths or `"eligible"`, `reason` is `manual` or `handoff`,
    /// and `limits` holds positive `max_bytes` and `max_files`.
    init(_ fields: AgentPanePageParams) throws {
        var untracked: Untracked?
        if fields.has("include_untracked") {
            if let paths = try? fields.texts("include_untracked") {
                untracked = .paths(paths)
            } else if try fields.text("include_untracked") == "eligible" {
                untracked = .eligible
            } else {
                throw AgentPanePageParams.Malformed()
            }
        }
        var reason: Reason?
        if let raw = try fields.text("reason") {
            guard let parsed = Reason(rawValue: raw) else { throw AgentPanePageParams.Malformed() }
            reason = parsed
        }
        var limits: Limits?
        if let object = try fields.object("limits", allowed: ["max_bytes", "max_files"]) {
            limits = Limits(maxBytes: try object.count("max_bytes"), maxFiles: try object.count("max_files"))
        }
        self.init(
            expectedRepositoryID: try fields.text("expected_repository_id"),
            expectedWorktreeID: try fields.text("expected_worktree_id"),
            includeUntracked: untracked,
            excludePaths: try fields.texts("exclude_paths"),
            reason: reason,
            limits: limits)
    }
}
