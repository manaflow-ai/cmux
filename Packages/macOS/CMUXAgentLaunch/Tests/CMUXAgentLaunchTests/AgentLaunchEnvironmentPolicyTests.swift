import CMUXAgentLaunch
import Testing

@Suite("AgentLaunchEnvironmentPolicy")
struct AgentLaunchEnvironmentPolicyTests {
    @Test("Preserves OMP config roots without persisting secrets")
    func preservesOmpConfigRootsWithoutPersistingSecrets() {
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: [
                "OPENAI_API_KEY": "secret-should-not-persist",
                "PI_CODING_AGENT_DIR": "/tmp/omp-agent",
                "PI_CONFIG_DIR": ".custom-omp",
            ],
            kind: "omp"
        )

        #expect(selected == [
            "PI_CODING_AGENT_DIR": "/tmp/omp-agent",
            "PI_CONFIG_DIR": ".custom-omp",
        ])
    }

    @Test("Preserves Campfire config roots and drops Pi-managed env")
    func preservesCampfireConfigRootsAndDropsManagedPackageDir() {
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: [
                "OPENAI_API_KEY": "secret-should-not-persist",
                "CAMPFIRE_CODING_AGENT_DIR": "/tmp/campfire-agent",
                "CAMPFIRE_CODING_AGENT_SESSION_DIR": "/tmp/campfire-sessions",
                "CAMPFIRE_RELAY_URL": "wss://relay.example/ws",
                // Campfire recomputes its extracted pi asset cache on every
                // boot; replaying a captured path would pin a resumed session
                // to the previous binary's cache after an upgrade.
                "PI_PACKAGE_DIR": "/tmp/stale-pi-cache",
                // A user's Pi session root must not leak into a Campfire
                // resume: the embedded Pi runtime would resolve session state
                // there while cmux's scanner reads the Campfire root.
                "PI_CODING_AGENT_SESSION_DIR": "/tmp/pi-sessions",
            ],
            kind: "campfire"
        )

        #expect(selected == [
            "CAMPFIRE_CODING_AGENT_DIR": "/tmp/campfire-agent",
            "CAMPFIRE_CODING_AGENT_SESSION_DIR": "/tmp/campfire-sessions",
            "CAMPFIRE_RELAY_URL": "wss://relay.example/ws",
        ])
    }

    @Test("Keeps PI_CODING_AGENT_SESSION_DIR for pi resumes")
    func keepsPiSessionDirForPi() {
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["PI_CODING_AGENT_SESSION_DIR": "/tmp/pi-sessions"],
            kind: "pi"
        )
        #expect(selected["PI_CODING_AGENT_SESSION_DIR"] == "/tmp/pi-sessions")
    }

    @Test("Keeps PI_PACKAGE_DIR for pi and omp resumes")
    func keepsPiPackageDirForPiKinds() {
        let selectedPi = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["PI_PACKAGE_DIR": "/nix/store/pi-package"],
            kind: "pi"
        )
        #expect(selectedPi["PI_PACKAGE_DIR"] == "/nix/store/pi-package")

        let selectedOmp = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["PI_PACKAGE_DIR": "/nix/store/pi-package"],
            kind: "omp"
        )
        #expect(selectedOmp["PI_PACKAGE_DIR"] == "/nix/store/pi-package")
    }

    @Test("Hook transport preserves routing and every auto-naming backend")
    func hookTransportPreservesAutoNamingInputsOnly() {
        let selected = AgentHookTransportEnvironmentPolicy().selectedEnvironment(from: [
            "CMUX_SOCKET_PATH": "/tmp/cmux.sock",
            "CMUX_SURFACE_ID": "surface:1",
            "CMUX_CUSTOM_CLAUDE_PATH": "/tmp/Claude Code/bin/claude",
            "CMUX_SOCKET_CAPABILITY": "must-not-persist",
            "CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP": "1",
            "ANTHROPIC_API_KEY": "anthropic-secret",
            "CLAUDE_CODE_USE_VERTEX": "1",
            "AWS_PROFILE": "bedrock-profile",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/gcp.json",
            "OPENAI_API_KEY": "openai-secret",
            "HTTPS_PROXY": "http://127.0.0.1:8080",
            "GROK_HOME": "/tmp/grok",
            "OPENCODE_CONFIG_DIR": "/tmp/opencode",
            "PI_CONFIG_DIR": "/tmp/pi",
            "UNRELATED_SECRET": "must-not-persist",
        ])

        #expect(selected["CMUX_SOCKET_PATH"] == "/tmp/cmux.sock")
        #expect(selected["CMUX_SURFACE_ID"] == "surface:1")
        #expect(selected["CMUX_CUSTOM_CLAUDE_PATH"] == "/tmp/Claude Code/bin/claude")
        #expect(selected["ANTHROPIC_API_KEY"] == "anthropic-secret")
        #expect(selected["CLAUDE_CODE_USE_VERTEX"] == "1")
        #expect(selected["AWS_PROFILE"] == "bedrock-profile")
        #expect(selected["GOOGLE_APPLICATION_CREDENTIALS"] == "/tmp/gcp.json")
        #expect(selected["OPENAI_API_KEY"] == "openai-secret")
        #expect(selected["HTTPS_PROXY"] == "http://127.0.0.1:8080")
        #expect(selected["GROK_HOME"] == "/tmp/grok")
        #expect(selected["OPENCODE_CONFIG_DIR"] == "/tmp/opencode")
        #expect(selected["PI_CONFIG_DIR"] == "/tmp/pi")
        #expect(selected["CMUX_SOCKET_CAPABILITY"] == nil)
        #expect(selected["CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP"] == nil)
        #expect(selected["UNRELATED_SECRET"] == nil)
    }
}
