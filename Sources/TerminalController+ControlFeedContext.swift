import CmuxControlSocket
import CoreFoundation
import Foundation

/// The feed-domain (workstream) witnesses are the byte-faithful bodies of the
/// former `v2FeedJump` / `v2FeedList` dispatchers. Both ran on the main actor
/// already (they were not `nonisolated`), so there is no per-read `v2MainSync`
/// hop to shed; the work is the same `FeedCoordinator.shared` reads the legacy
/// bodies performed, with the per-item encoding (`FeedSocketEncoding.itemDict`)
/// bridged to `JSONValue` so the wire bytes match exactly.
///
/// Only the MAIN-ACTOR feed methods move here. The worker-lane feed methods
/// (`feed.push`, `feed.permission.reply`, `feed.question.reply`,
/// `feed.exit_plan.reply`) stay on the app-side socket-worker path.
extension TerminalController: ControlFeedContext {
    func controlFeedResolvePossibleSurface(workstreamID: String) -> Bool {
        FeedCoordinator.shared.resolvePossibleSurface(for: workstreamID)
    }

    func controlFeedSnapshotItems(pendingOnly: Bool) -> [JSONValue] {
        FeedCoordinator.shared.snapshot(pendingOnly: pendingOnly).map { item in
            // `FeedSocketEncoding.itemDict` only ever produces valid JSON
            // (strings, bools, arrays, nested dicts), so the bridge never fails;
            // the empty-object fallback exists solely to keep the map total.
            JSONValue(foundationObject: FeedSocketEncoding.itemDict(item)) ?? .object([:])
        }
    }

    func v2AgentAttentionBegin(
        params: [String: Any]
    ) -> V2CallResult {
        let observationEpochValue = params["observation_epoch"]
        let observationEpoch = agentAttentionEpoch(observationEpochValue)
        let surfaceIdValue = params["surface_id"]
        let surfaceId: UUID?
        if let surfaceIdValue {
            guard let parsedSurfaceId = agentAttentionUUID(surfaceIdValue) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "agent_attention.invalid_parameters",
                        defaultValue: "Invalid agent attention parameters."
                    ),
                    data: nil
                )
            }
            surfaceId = parsedSurfaceId
        } else {
            surfaceId = nil
        }
        guard let source = agentAttentionSource(params["source"]),
              let sessionId = agentAttentionOpaqueID(params["session_id"]),
              let observationId = agentAttentionOpaqueID(
                  params["observation_id"]
              ),
              let scopeId = agentAttentionOpaqueID(params["scope_id"]),
              let workspaceId = agentAttentionUUID(params["workspace_id"]),
              let generation = agentAttentionProcessGeneration(params),
              observationEpochValue == nil || observationEpoch != nil else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "agent_attention.invalid_parameters",
                    defaultValue: "Invalid agent attention parameters."
                ),
                data: nil
            )
        }
        let began = FeedCoordinator.shared.beginObservedAgentAttention(
            source: source,
            sessionId: sessionId,
            observationId: observationId,
            scopeId: scopeId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            processGeneration: generation,
            observationEpoch: observationEpoch
        )
        return .ok(["status": began ? "began" : "ignored"])
    }

    func v2AgentAttentionEnd(
        params: [String: Any]
    ) -> V2CallResult {
        let boundaryEpochValue = params["boundary_epoch"]
        let boundaryEpoch = agentAttentionEpoch(boundaryEpochValue)
        let observationIdValue = params["observation_id"]
        let observationId = agentAttentionOpaqueID(observationIdValue)
        let scopeIdValue = params["scope_id"]
        let scopeId = agentAttentionOpaqueID(scopeIdValue)
        let hasConclusionIdentity = observationId != nil
            || scopeId != nil
            || boundaryEpoch != nil
        guard let source = agentAttentionSource(params["source"]),
              let sessionId = agentAttentionOpaqueID(params["session_id"]),
              let generation = agentAttentionProcessGeneration(params),
              boundaryEpochValue == nil || boundaryEpoch != nil,
              observationIdValue == nil || observationId != nil,
              scopeIdValue == nil || scopeId != nil,
              hasConclusionIdentity
        else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "agent_attention.invalid_parameters",
                    defaultValue: "Invalid agent attention parameters."
                ),
                data: nil
            )
        }
        let ended = FeedCoordinator.shared.endObservedAgentAttention(
            source: source,
            sessionId: sessionId,
            observationId: observationId,
            scopeId: scopeId,
            processGeneration: generation,
            boundaryEpoch: boundaryEpoch
        )
        return .ok([
            "status": "ended",
            "ended_count": ended,
        ])
    }

    private func agentAttentionSource(_ raw: Any?) -> String? {
        guard let source = (raw as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            let integration = BuiltInAgentIntegration(
                feedSourceName: source
            ),
            integration.approvalDetectionMechanism
                == .nativePostPolicyObserver else {
            return nil
        }
        return source
    }

    private func agentAttentionOpaqueID(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        return AgentAttentionOpaqueIdentifier(rawValue: value)?.rawValue
    }

    private func agentAttentionUUID(_ raw: Any?) -> UUID? {
        guard let value = (raw as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return UUID(uuidString: value)
    }

    private func agentAttentionEpoch(_ raw: Any?) -> UInt64? {
        guard let value = raw as? String,
              !value.isEmpty,
              value.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
            return nil
        }
        return UInt64(value)
    }

    private func agentAttentionProcessGeneration(
        _ params: [String: Any]
    ) -> AgentPIDProcessIdentity? {
        guard let pidValue = agentAttentionInt64(params["pid"]),
              pidValue > 0,
              pidValue <= Int64(Int32.max),
              let startSeconds = agentAttentionInt64(
                  params["pid_start_seconds"]
              ),
              startSeconds >= 0,
              let startMicroseconds = agentAttentionInt64(
                  params["pid_start_microseconds"]
              ),
              (0 ..< 1_000_000).contains(startMicroseconds) else {
            return nil
        }
        return AgentPIDProcessIdentity(
            pid: pid_t(pidValue),
            startSeconds: startSeconds,
            startMicroseconds: startMicroseconds
        )
    }

    private func agentAttentionInt64(_ raw: Any?) -> Int64? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        if let value = raw as? Int {
            return Int64(value)
        }
        if CFNumberIsFloatType(number) {
            return Int64(exactly: number.doubleValue)
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              number.compare(NSNumber(value: Int64.min))
                != .orderedAscending,
              number.compare(NSNumber(value: Int64.max))
                != .orderedDescending else {
            return nil
        }
        return number.int64Value
    }
}
