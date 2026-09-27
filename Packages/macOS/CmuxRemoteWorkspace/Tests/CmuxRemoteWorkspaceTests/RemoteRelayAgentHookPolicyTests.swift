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
        return RemoteRelayCommandPolicy().evaluate(commandLine: line, workspaceAliases: [:], surfaceAliases: [:])
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
            "payload": #"{"session_id":"sess-1","cwd":"/home/leo/repo","transcript_path":"/Users/leo/.ssh/id_ed25519","nested":{"transcriptPath":"/etc/passwd","keep":1}}"#,
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

    /// SessionStart may carry a bounded remote cwd and ancestor words, which admission moves into the replay environment.
    @Test("SessionStart may carry a bounded remote cwd and ancestor words")
    func sessionStartResumeBindingIsAdmitted() throws {
        let parameters = hookParameters(overrides: [
            "remote_cwd": "/home/leo/repo",
            "ancestor_executables": [["-zsh"], ["env", "ANTHROPIC_API_KEY=", "teamclaude"]],
        ])
        #expect(authorize(parameters) == .allowed)
        #expect(try evaluate(parameters) == .allow)

        var stamped = parameters
        stamped[RemoteRelayAuthorizationPolicy.remoteWorkspaceIDKey] = owner.uuidString
        let admitted = try #require(RemoteRelayAgentHookAdmission().queueParameters(from: stamped))
        let environment = try #require(admitted["environment"] as? [String: String])
        #expect(environment["CMUX_AGENT_HOOK_RELAY_REMOTE_CWD"] == "/home/leo/repo")
        #expect(environment["CMUX_AGENT_HOOK_RELAY_ANCESTOR_EXECUTABLES"]
            == #"[["-zsh"],["env","ANTHROPIC_API_KEY=","teamclaude"]]"#)
        #expect(environment["CMUX_WORKSPACE_ID"] == owner.uuidString)
        #expect(admitted["remote_cwd"] == nil)
        #expect(admitted["ancestor_executables"] == nil)
    }

    /// Resume binding fields are refused on every event but SessionStart.
    @Test("resume binding fields are refused outside SessionStart", arguments: ["stop", "prompt-submit", "session-end"])
    func resumeBindingFieldsRequireSessionStart(subcommand: String) throws {
        for (key, value) in [("remote_cwd", "/home/leo/repo" as Any), ("ancestor_executables", [["teamclaude"]] as Any)] {
            let parameters = hookParameters(overrides: ["subcommand": subcommand, key: value])
            #expect(authorize(parameters) != .allowed, "\(subcommand) \(key)")
            #expect(try evaluate(parameters) != .allow, "\(subcommand) \(key)")
        }
    }

    /// Out-of-bounds or mistyped resume binding fields are denied.
    @Test("out-of-bounds resume binding fields are denied", arguments: [
        "relative", "control", "long-cwd", "cwd-type",
        "too-many-ancestors", "too-many-words", "long-word", "total-bytes", "empty-ancestor", "word-type", "flat",
    ])
    func outOfBoundsResumeBindingFieldsAreDenied(shape: String) throws {
        let word = String(repeating: "w", count: 128)
        let override: (String, Any) = switch shape {
        case "relative": ("remote_cwd", "home/leo")
        case "control": ("remote_cwd", "/home/leo\u{1B}[2J")
        case "long-cwd": ("remote_cwd", "/" + String(repeating: "x", count: 1_024))
        case "cwd-type": ("remote_cwd", 7)
        case "too-many-ancestors": ("ancestor_executables", Array(repeating: ["a"], count: 9))
        case "too-many-words": ("ancestor_executables", [Array(repeating: "a", count: 7)])
        case "long-word": ("ancestor_executables", [[word + "w"]])
        case "total-bytes": ("ancestor_executables", Array(repeating: [word, word, word], count: 8))
        case "empty-ancestor": ("ancestor_executables", [[]] as [[String]])
        case "word-type": ("ancestor_executables", [["ok", 7] as [Any]])
        default: ("ancestor_executables", ["flat"])
        }
        let parameters = hookParameters(overrides: [override.0: override.1])
        #expect(authorize(parameters) != .allowed, "\(shape)")
        #expect(try evaluate(parameters) != .allow, "\(shape)")
    }

    /// A relayed hook cannot carry a command, argv, environment, or settings alongside the binding.
    @Test("a relayed hook cannot carry a command, argv, environment, or settings", arguments: [
        "command", "argv", "arguments", "launch_command", "environment", "settings", "executable_path",
    ])
    func commandBearingResumeFieldsAreDenied(key: String) throws {
        let parameters = hookParameters(overrides: [
            "remote_cwd": "/home/leo/repo",
            key: key == "environment" ? ["CLAUDE_CONFIG_DIR": "/tmp"] as Any : ["claude", "--resume", "x"] as Any,
        ])
        #expect(authorize(parameters) != .allowed, "\(key)")
        #expect(try evaluate(parameters) != .allow, "\(key)")
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
