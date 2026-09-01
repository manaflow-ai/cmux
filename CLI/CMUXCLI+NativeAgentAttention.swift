import Darwin
import Foundation

extension CMUXCLI {
    private enum NativeAgentAttentionAction: String {
        case identify
        case begin
        case end
    }

    /// Hidden adapter seam for agents whose native runtime can confirm an
    /// approval wait only after their ordinary pre-tool hook returns.
    ///
    /// The helper captures the exact process generation itself, validates the
    /// target and opaque correlation identifiers, and publishes through the
    /// app's shared attention reconciler. Integrations never write lifecycle
    /// state directly.
    func runNativeAgentAttention(
        source: BuiltInAgentIntegration,
        commandArgs: [String],
        socketPath: String,
        socketPassword: String?
    ) throws {
        guard source.approvalDetectionMechanism
            == .nativePostPolicyObserver else {
            throw CLIError(
                message: String(
                    localized: "agent_attention.observer_unavailable",
                    defaultValue: "Native approval observer unavailable."
                )
            )
        }
        guard let rawAction = commandArgs.first?.lowercased(),
              let action = NativeAgentAttentionAction(rawValue: rawAction),
              let pidValue = optionValue(commandArgs, name: "--pid"),
              let pid = Int(pidValue),
              pid > 0,
              pid <= Int(Int32.max),
              let processIdentity = AgentPIDProcessIdentity(
                  agentTurnPID: pid
              ),
              processIdentity.liveness == .live else {
            throw CLIError(
                message: String(
                    localized: "agent_attention.invalid_process",
                    defaultValue: "Invalid native approval observer process."
                )
            )
        }

        if action == .identify {
            // Only the direct child spawned synchronously by the agent may ask
            // for its generation. A caller cannot identify an unrelated PID.
            guard pid == Int(getppid()),
                  let data = try? JSONSerialization.data(
                      withJSONObject: [
                          "pid": processIdentity.pid,
                          "pid_start_seconds":
                              processIdentity.startSeconds,
                          "pid_start_microseconds":
                              processIdentity.startMicroseconds,
                      ],
                      options: [.sortedKeys]
                  ),
                  let output = String(data: data, encoding: .utf8)
            else {
                throw CLIError(
                    message: String(
                        localized: "agent_attention.invalid_identity_request",
                        defaultValue: "Invalid native approval identity request."
                    )
                )
            }
            print(output)
            return
        }

        guard let expectedStartSeconds = optionValue(
            commandArgs,
            name: "--pid-start-seconds"
        ).flatMap(Int64.init),
            expectedStartSeconds >= 0,
            let expectedStartMicroseconds = optionValue(
                commandArgs,
                name: "--pid-start-microseconds"
            ).flatMap(Int64.init),
            (0 ..< 1_000_000).contains(expectedStartMicroseconds),
            processIdentity.startSeconds == expectedStartSeconds,
            processIdentity.startMicroseconds
                == expectedStartMicroseconds
        else {
            throw CLIError(
                message: String(
                    localized: "agent_attention.process_replaced",
                    defaultValue: "Native approval observer process was replaced."
                )
            )
        }

        let rawObservationId = optionValue(
            commandArgs,
            name: "--observation-id"
        )
        let rawScopeId = optionValue(commandArgs, name: "--scope-id")
        let observationId = Self.nativeAttentionOpaqueIdentifier(
            rawObservationId
        )
        let scopeId = Self.nativeAttentionOpaqueIdentifier(rawScopeId)
        if rawObservationId != nil, observationId == nil {
            throw CLIError(
                message: String(
                    localized: "agent_attention.invalid_observation_id",
                    defaultValue: "Invalid native approval observation identifier."
                )
            )
        }
        if rawScopeId != nil, scopeId == nil {
            throw CLIError(
                message: String(
                    localized: "agent_attention.invalid_scope_id",
                    defaultValue: "Invalid native approval scope identifier."
                )
            )
        }
        guard let sessionId = Self.nativeAttentionOpaqueIdentifier(
            optionValue(commandArgs, name: "--session-id")
        ) else {
            throw CLIError(
                message: String(
                    localized: "agent_attention.invalid_session_id",
                    defaultValue: "Invalid native approval session identifier."
                )
            )
        }

        var params: [String: Any] = [
            "source": source.feedSourceName,
            "session_id": sessionId,
            "pid": processIdentity.pid,
            "pid_start_seconds": processIdentity.startSeconds,
            "pid_start_microseconds": processIdentity.startMicroseconds,
        ]

        switch action {
        case .identify:
            return
        case .begin:
            guard let observationId,
                  let scopeId,
                  let workspaceIdValue = optionValue(
                      commandArgs,
                      name: "--workspace-id"
                  ),
                  let workspaceId = UUID(uuidString: workspaceIdValue)
            else {
                throw CLIError(
                    message: String(
                        localized: "agent_attention.invalid_begin_target",
                        defaultValue: "Invalid native approval begin target."
                    )
                )
            }
            params["observation_id"] = observationId
            params["scope_id"] = scopeId
            params["workspace_id"] = workspaceId.uuidString
            if let surfaceIdValue = optionValue(
                commandArgs,
                name: "--surface-id"
            ) {
                guard let surfaceId = UUID(uuidString: surfaceIdValue) else {
                    throw CLIError(
                        message: String(
                            localized: "agent_attention.invalid_surface_id",
                            defaultValue: "Invalid native approval surface identifier."
                        )
                    )
                }
                params["surface_id"] = surfaceId.uuidString
            }
        case .end:
            guard observationId != nil || scopeId != nil else {
                throw CLIError(
                    message: String(
                        localized: "agent_attention.missing_end_identifier",
                        defaultValue: "Native approval end requires an observation or scope identifier."
                    )
                )
            }
            if let observationId {
                params["observation_id"] = observationId
            }
            if let scopeId {
                params["scope_id"] = scopeId
            }
        }

        try sendAgentAttentionV2Message(
            method: action == .begin
                ? "agent.attention.begin"
                : "agent.attention.end",
            params: params,
            socketPath: socketPath,
            socketPassword: socketPassword
        )
    }

    private static let nativeAttentionDeliveryAttemptCount = 2
    private static let nativeAttentionDeliveryTimeoutSeconds: TimeInterval = 2

    private func sendAgentAttentionV2Message(
        method: String,
        params: [String: Any],
        socketPath: String,
        socketPassword: String?
    ) throws {
        try sendAgentAttentionV2Message(
            method: method,
            params: params,
            socketPath: socketPath,
            socketPassword: socketPassword,
            deadline: Date.now.addingTimeInterval(
                Self.nativeAttentionDeliveryTimeoutSeconds
            )
        )
    }

    private func sendAgentAttentionV2Message(
        method: String,
        params: [String: Any],
        socketPath: String,
        socketPassword: String?,
        deadline: Date
    ) throws {
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        try client.connect(deadline: deadline)
        try authenticateClientIfNeeded(
            client,
            explicitPassword: socketPassword,
            socketPath: socketPath,
            responseTimeout: max(deadline.timeIntervalSinceNow, 0.05),
            deadline: deadline
        )
        _ = try client.sendV2(
            method: method,
            params: params,
            responseTimeout: max(deadline.timeIntervalSinceNow, 0.05)
        )
    }

    /// Delivers one attention mutation with an acknowledgement and one
    /// immediate retry inside a single bounded deadline. Begin/end mutations
    /// are keyed by opaque observation identifiers, so replaying a request
    /// after a lost response is idempotent while avoiding fire-and-forget
    /// attention state that can strand a stale Needs Input badge.
    func sendAcknowledgedAgentAttentionV2MessageWithRetry(
        method: String,
        params: [String: Any],
        socketPath: String,
        socketPassword: String?
    ) throws {
        let deadline = Date.now.addingTimeInterval(
            Self.nativeAttentionDeliveryTimeoutSeconds
        )
        var lastError: Error?
        for attempt in 0 ..< Self.nativeAttentionDeliveryAttemptCount {
            do {
                try sendAgentAttentionV2Message(
                    method: method,
                    params: params,
                    socketPath: socketPath,
                    socketPassword: socketPassword,
                    deadline: deadline
                )
                return
            } catch {
                lastError = error
                guard attempt + 1 < Self.nativeAttentionDeliveryAttemptCount,
                      deadline.timeIntervalSinceNow > 0 else {
                    break
                }
            }
        }
        if let lastError { throw lastError }
    }

    static func nativeAttentionOpaqueIdentifier(
        _ value: String?
    ) -> String? {
        guard let value else { return nil }
        return AgentAttentionOpaqueIdentifier(rawValue: value)?.rawValue
    }
}
