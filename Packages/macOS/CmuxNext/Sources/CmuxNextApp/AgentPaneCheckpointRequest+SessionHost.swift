import CmuxNextAgentPane
import CmuxNextDaemon

extension AgentPaneCheckpointRequest {
    /// The session host's params (cmux-tui `spec/resource-operations-v2.json`
    /// `git.checkpoint.*`): the folder as `path` and the operation's fields,
    /// with nil fields left out so the session host applies its defaults. A
    /// mutation's key is not here: it goes in the request envelope. A `get`
    /// by key carries it here, as the lookup field.
    var sessionHostParams: [String: JSONValue] {
        var params: [String: JSONValue] = ["path": .string(cwd)]
        switch self {
        case .create(_, let options, _):
            params.merge(options.sessionHostFields) { _, field in field }
        case .get(_, .checkpointID(let id)):
            params["checkpoint_id"] = .string(id)
        case .get(_, .idempotencyKey(let key)):
            params["idempotency_key"] = .string(key)
        case .list(_, let cursor, let limit, let includeCandidates):
            if let cursor { params["cursor"] = .string(cursor) }
            if let limit { params["limit"] = .number(Double(limit)) }
            if let includeCandidates { params["include_candidates"] = .bool(includeCandidates) }
        case .pin(_, let checkpointID, let pinID, let reason, _):
            params["checkpoint_id"] = .string(checkpointID)
            params["pin_id"] = .string(pinID)
            params["reason"] = .string(reason)
        case .unpin(_, let checkpointID, let pinID, _):
            params["checkpoint_id"] = .string(checkpointID)
            params["pin_id"] = .string(pinID)
        }
        return params
    }
}

extension AgentPaneCheckpointCreate {
    /// The create's own fields, nil ones left out.
    var sessionHostFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if let expectedRepositoryID { fields["expected_repository_id"] = .string(expectedRepositoryID) }
        if let expectedWorktreeID { fields["expected_worktree_id"] = .string(expectedWorktreeID) }
        switch includeUntracked {
        case .paths(let paths): fields["include_untracked"] = .array(paths.map { .string($0) })
        case .eligible: fields["include_untracked"] = .string("eligible")
        case nil: break
        }
        if let excludePaths { fields["exclude_paths"] = .array(excludePaths.map { .string($0) }) }
        if let reason { fields["reason"] = .string(reason.rawValue) }
        if let limits {
            var object: [String: JSONValue] = [:]
            if let maxBytes = limits.maxBytes { object["max_bytes"] = .number(Double(maxBytes)) }
            if let maxFiles = limits.maxFiles { object["max_files"] = .number(Double(maxFiles)) }
            fields["limits"] = .object(object)
        }
        return fields
    }
}
