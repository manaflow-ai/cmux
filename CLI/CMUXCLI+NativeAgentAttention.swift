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
                message:
                    "\(source.feedSourceName) has no native approval observer"
            )
        }
        guard let rawAction = commandArgs.first?.lowercased(),
              let action = NativeAgentAttentionAction(rawValue: rawAction),
              let pidValue = optionValue(commandArgs, name: "--pid"),
              let pid = Int(pidValue),
              let processIdentity = AgentPIDProcessIdentity(
                  agentTurnPID: pid
              ),
              processIdentity.liveness == .live else {
            throw CLIError(message: "Invalid native agent attention process")
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
                    message: "Invalid native attention identity request"
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
                message: "Native agent attention process was replaced"
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
            throw CLIError(message: "Invalid native attention observation id")
        }
        if rawScopeId != nil, scopeId == nil {
            throw CLIError(message: "Invalid native attention scope id")
        }

        var params: [String: Any] = [
            "source": source.feedSourceName,
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
                    message: "Invalid native attention begin target"
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
                        message: "Invalid native attention surface id"
                    )
                }
                params["surface_id"] = surfaceId.uuidString
            }
        case .end:
            guard observationId != nil || scopeId != nil else {
                throw CLIError(
                    message:
                        "Native attention end requires an observation or scope"
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

    private func sendAgentAttentionV2Message(
        method: String,
        params: [String: Any],
        socketPath: String,
        socketPassword: String?
    ) throws {
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        let deadline = Date.now.addingTimeInterval(2)
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

    func sendBestEffortAgentAttentionV2Message(
        method: String,
        params: [String: Any],
        socketPath: String,
        socketPassword: String?
    ) {
        let frame: [String: Any] = [
            "method": method,
            "params": params,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: frame
        ),
        let line = String(data: data, encoding: .utf8) else {
            return
        }
        sendBestEffortFeedTelemetry(
            socketPath: socketPath,
            line: line,
            socketPassword: socketPassword
        )
    }

    static func nativeAttentionOpaqueIdentifier(
        _ value: String?
    ) -> String? {
        AgentAttentionWireValidation.opaqueIdentifier(value)
    }
}
