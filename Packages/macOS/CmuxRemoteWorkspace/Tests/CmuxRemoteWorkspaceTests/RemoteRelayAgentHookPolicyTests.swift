import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Remote relay agent hook admission")
struct RemoteRelayAgentHookPolicyTests {
    private let owner = UUID()
    private let ownedSurface = UUID()

    /// Builds an in-contract hook request for the owned surface, with optional overrides.
    private func hookParameters(
        surfaceID: UUID? = nil,
        workspaceID: UUID? = nil,
        overrides: [String: Any] = [:]
    ) -> [String: Any] {
        var parameters: [String: Any] = [
            "workspace_id": (workspaceID ?? owner).uuidString,
            "surface_id": (surfaceID ?? ownedSurface).uuidString,
            "agent": "claude",
            "subcommand": "session-start",
            "payload": #"{"session_id":"sess-1","hook_event_name":"SessionStart"}"#,
            "relay_backed": true,
            "caller_tty": "/dev/pts/3",
        ]
        for (key, value) in overrides { parameters[key] = value }
        return parameters
    }

    /// Runs the app-side authorization gate with owner provenance stamped.
    private func authorize(_ parameters: [String: Any]) -> RemoteRelayAuthorizationPolicy.Decision {
        var stamped = parameters
        stamped[RemoteRelayAuthorizationPolicy.remoteWorkspaceIDKey] = owner.uuidString
        return RemoteRelayAuthorizationPolicy().validate(
            method: "agent.hook.enqueue",
            parameters: stamped,
            ownerWorkspaceID: owner,
            surfaceIDs: [ownedSurface]
        )
    }

    /// Runs the relay-side syntax gate on the request as one JSON-RPC line.
    private func evaluate(_ parameters: [String: Any]) throws -> RemoteRelayCommandPolicy.Verdict {
        let request: [String: Any] = ["id": "hook", "method": "agent.hook.enqueue", "params": parameters]
        let line = try JSONSerialization.data(withJSONObject: request)
        return RemoteRelayCommandPolicy().evaluate(
            commandLine: line, workspaceAliases: [owner: owner], surfaceAliases: [ownedSurface: ownedSurface]
        )
    }

    /// A lifecycle hook for an owned surface is admitted.
    @Test("a lifecycle hook for an owned surface is admitted", arguments: [
        "session-start", "prompt-submit", "stop", "notification", "session-end", "pre-tool-use",
    ])
    func ownedLifecycleHookIsAllowed(subcommand: String) throws {
        let parameters = hookParameters(overrides: ["subcommand": subcommand])
        #expect(authorize(parameters) == .allowed)
        #expect(try evaluate(parameters) == .allow)
    }

    /// `caller_tty` is optional.
    @Test("caller_tty is optional")
    func callerTTYIsOptional() throws {
        var parameters = hookParameters()
        parameters.removeValue(forKey: "caller_tty")
        #expect(authorize(parameters) == .allowed)
        #expect(try evaluate(parameters) == .allow)
    }

    /// Hooks cannot target a surface or workspace the relay does not own.
    @Test("hooks cannot target a surface or workspace the relay does not own")
    func foreignTargetsAreDenied() {
        #expect(authorize(hookParameters(surfaceID: UUID())) != .allowed)
        #expect(authorize(hookParameters(workspaceID: UUID())) != .allowed)
    }

    /// Hooks require explicit workspace and surface selectors.
    @Test("hooks require explicit workspace and surface selectors", arguments: ["workspace_id", "surface_id"])
    func missingSelectorIsDenied(key: String) {
        var parameters = hookParameters()
        parameters.removeValue(forKey: key)
        #expect(authorize(parameters) != .allowed)
    }

    /// Decision hooks, other agents, and local replay fields stay local-only.
    @Test("decision hooks, other agents, and local replay fields stay local-only", arguments: [
        ("subcommand", "feed"),
        ("subcommand", "cron-create-guard"),
        ("subcommand", "auto-name"),
        ("agent", "codex"),
        ("relay_backed", "false"),
        ("environment", "{}"),
        ("socket_path", "/tmp/cmux.sock"),
        ("command", "id"),
        ("payload", "oversized"),
        ("caller_tty", "nul"),
    ])
    func outOfContractParametersAreDenied(key: String, value: String) throws {
        var override: Any = value
        switch (key, value) {
        case ("relay_backed", _): override = false
        case ("environment", _): override = ["CMUX_AGENT_LAUNCH_EXECUTABLE": "/bin/sh"]
        case ("payload", _): override = String(repeating: "x", count: 8 * 1_024 + 1)
        case ("caller_tty", _): override = "/dev/pts/3\u{0}"
        default: break
        }
        let parameters = hookParameters(overrides: [key: override])
        #expect(authorize(parameters) != .allowed, "\(key)=\(value)")
        #expect(try evaluate(parameters) != .allow, "\(key)=\(value)")
    }

    /// Admission derives the replay environment from the authorized selectors.
    @Test("admission derives the replay environment from the authorized selectors")
    func admissionRebuildsEnvironmentFromSelectors() throws {
        let ownerKey = RemoteRelayAuthorizationPolicy.remoteWorkspaceIDKey
        var parameters = hookParameters(overrides: [
            "payload": #"{"session_id":"sess-1","cwd":"/home/dev/repo","transcript_path":"/Users/dev/.ssh/id_ed25519","nested":{"transcriptPath":"/etc/passwd","keep":1}}"#,
        ])
        parameters[ownerKey] = owner.uuidString
        parameters["_cmux_remote_connection_id"] = UUID().uuidString

        let admitted = try #require(RemoteRelayAgentHookAdmission().queueParameters(from: parameters))
        #expect(admitted["environment"] as? [String: String] == [
            "CMUX_WORKSPACE_ID": owner.uuidString,
            "CMUX_SURFACE_ID": ownedSurface.uuidString,
        ])
        #expect(admitted["relay_backed"] as? Bool == true)
        #expect(admitted["caller_tty"] as? String == "/dev/pts/3")
        #expect(admitted[ownerKey] as? String == owner.uuidString)
        #expect(admitted["workspace_id"] == nil)
        #expect(admitted["_cmux_remote_connection_id"] == nil)
        #expect(admitted["payload"] as? String == #"{"nested":{"keep":1},"session_id":"sess-1"}"#)
    }

    /// Admission rejects requests without UUID selectors.
    @Test("admission rejects requests without UUID selectors")
    func admissionRequiresSelectors() {
        #expect(RemoteRelayAgentHookAdmission().queueParameters(
            from: hookParameters(overrides: ["surface_id": "surface:1"])
        ) == nil)
        var missingWorkspace = hookParameters()
        missingWorkspace.removeValue(forKey: "workspace_id")
        #expect(RemoteRelayAgentHookAdmission().queueParameters(from: missingWorkspace) == nil)
        #expect(RemoteRelayAgentHookAdmission().portablePayload("not json") == "{}")
    }

    /// The direct barrier stays unavailable through the relay.
    @Test("the direct barrier stays unavailable through the relay")
    func barrierIsDenied() {
        let decision = RemoteRelayAuthorizationPolicy().validate(
            method: "agent.hook.barrier",
            parameters: hookParameters(),
            ownerWorkspaceID: owner,
            surfaceIDs: [ownedSurface]
        )
        #expect(decision == .denied(code: "remote_relay_method_denied", message: "Relay method is not permitted"))
    }
}
