import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Remote relay agent hook admission")
struct RemoteRelayAgentHookPolicyTests {
    private let owner = UUID()
    private let ownedSurface = UUID()

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

    private func evaluate(_ parameters: [String: Any]) throws -> RemoteRelayCommandPolicy.Verdict {
        let request: [String: Any] = ["id": "hook", "method": "agent.hook.enqueue", "params": parameters]
        let line = try JSONSerialization.data(withJSONObject: request)
        return RemoteRelayCommandPolicy().evaluate(commandLine: line, workspaceAliases: [:], surfaceAliases: [:])
    }

    @Test("a lifecycle hook for an owned surface is admitted", arguments: [
        "session-start", "prompt-submit", "stop", "notification", "session-end", "pre-tool-use",
    ])
    func ownedLifecycleHookIsAllowed(subcommand: String) throws {
        let parameters = hookParameters(overrides: ["subcommand": subcommand])
        #expect(authorize(parameters) == .allowed)
        #expect(try evaluate(parameters) == .allow)
    }

    @Test("caller_tty is optional")
    func callerTTYIsOptional() throws {
        var parameters = hookParameters()
        parameters.removeValue(forKey: "caller_tty")
        #expect(authorize(parameters) == .allowed)
        #expect(try evaluate(parameters) == .allow)
    }

    @Test("hooks cannot target a surface or workspace the relay does not own")
    func foreignTargetsAreDenied() {
        #expect(authorize(hookParameters(surfaceID: UUID())) != .allowed)
        #expect(authorize(hookParameters(workspaceID: UUID())) != .allowed)
    }

    @Test("hooks require explicit workspace and surface selectors", arguments: ["workspace_id", "surface_id"])
    func missingSelectorIsDenied(key: String) {
        var parameters = hookParameters()
        parameters.removeValue(forKey: key)
        #expect(authorize(parameters) != .allowed)
    }

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
