import Foundation

extension CMUXCLI {
    enum RejectedClaudeRestoreBindingReconciliation {
        case matching
        case notMatching
        case inconclusive

        var preservesExistingBinding: Bool {
            switch self {
            case .matching, .inconclusive:
                true
            case .notMatching:
                false
            }
        }
    }

    /// Preserves matching/inconclusive state and retires only an observed prior owner.
    func reconcileRejectedClaudeRestoreBinding(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String,
        acceptedSessionId: String
    ) -> RejectedClaudeRestoreBindingReconciliation {
        do {
            let payload = try client.sendV2(
                method: "surface.resume.get",
                params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                ]
            )
            switch payload["resume_binding"] {
            case .some(let binding as [String: Any]):
                guard normalizedHookValue(binding["source"] as? String) == "agent-hook" else {
                    return .notMatching
                }
                let currentSessionId = normalizedHookValue(binding["checkpoint_id"] as? String)
                let currentKind = normalizedHookValue(binding["kind"] as? String)?.lowercased()
                if (currentKind == nil || currentKind == "claude"),
                   currentSessionId == normalizedHookValue(acceptedSessionId) {
                    return .matching
                }
                guard currentKind == "claude" else {
                    return .inconclusive
                }
                let updatedAt = (binding["updated_at"] as? NSNumber)?.doubleValue
                let clearOutcome = clearAgentSurfaceResumeBindingOutcome(
                    client: client,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    sessionId: currentSessionId,
                    updatedAt: updatedAt?.isFinite == true ? updatedAt : nil
                )
                switch clearOutcome {
                case .cleared:
                    return .notMatching
                case .checkpointDidNotOwnBinding, .failed:
                    return .inconclusive
                }
            case .some(let value) where value is NSNull:
                return .notMatching
            default:
                return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }
}
