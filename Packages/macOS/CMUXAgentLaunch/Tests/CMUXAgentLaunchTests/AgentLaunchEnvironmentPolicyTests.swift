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
        let partitioned = AgentHookTransportEnvironmentPolicy().partitionedEnvironment(from: [
            "CMUX_SOCKET_PATH": "/tmp/cmux.sock",
            "CMUX_SURFACE_ID": "surface:1",
            "CMUX_CUSTOM_CLAUDE_PATH": "/tmp/Claude Code/bin/claude",
            "CMUX_AGENT_HOOK_DELIVERY_ID": "transport-only-id",
            "CMUX_SOCKET_CAPABILITY": "must-not-persist",
            "CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP": "1",
            "ANTHROPIC_API_KEY": "anthropic-secret",
            "CLAUDE_CODE_USE_VERTEX": "1",
            "AWS_PROFILE": "bedrock-profile",
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/gcp.json",
            "OPENAI_API_KEY": "openai-secret",
            "XAI_API_KEY": "grok-secret",
            "XAI_BASE_URL": "https://xai.example.test/v1",
            "GEMINI_API_KEY": "gemini-secret",
            "OPENROUTER_API_KEY": "openrouter-secret",
            "CUSTOM_AUTH_TOKEN": "custom-auth-secret",
            "CUSTOM_ACCESS_TOKEN": "custom-access-secret",
            "CUSTOM_CLIENT_SECRET": "custom-client-secret",
            "HTTPS_PROXY": "http://127.0.0.1:8080",
            "GROK_HOME": "/tmp/grok",
            "OPENCODE_CONFIG_DIR": "/tmp/opencode",
            "PI_CONFIG_DIR": "/tmp/pi",
            "UNRELATED_SECRET": "must-not-persist",
        ])

        #expect(partitioned.durable["CMUX_SOCKET_PATH"] == "/tmp/cmux.sock")
        #expect(partitioned.durable["CMUX_SURFACE_ID"] == "surface:1")
        #expect(partitioned.durable["CMUX_CUSTOM_CLAUDE_PATH"] == "/tmp/Claude Code/bin/claude")
        #expect(partitioned.durable["CLAUDE_CODE_USE_VERTEX"] == "1")
        #expect(partitioned.durable["AWS_PROFILE"] == "bedrock-profile")
        #expect(partitioned.durable["HTTPS_PROXY"] == "http://127.0.0.1:8080")
        #expect(partitioned.durable["XAI_BASE_URL"] == "https://xai.example.test/v1")
        #expect(partitioned.durable["GROK_HOME"] == "/tmp/grok")
        #expect(partitioned.durable["OPENCODE_CONFIG_DIR"] == "/tmp/opencode")
        #expect(partitioned.durable["PI_CONFIG_DIR"] == "/tmp/pi")

        #expect(partitioned.ephemeral["ANTHROPIC_API_KEY"] == "anthropic-secret")
        #expect(partitioned.ephemeral["AWS_SECRET_ACCESS_KEY"] == "aws-secret")
        #expect(partitioned.durable["GOOGLE_APPLICATION_CREDENTIALS"] == "/tmp/gcp.json")
        #expect(partitioned.ephemeral["OPENAI_API_KEY"] == "openai-secret")
        #expect(partitioned.ephemeral["XAI_API_KEY"] == "grok-secret")
        #expect(partitioned.ephemeral["GEMINI_API_KEY"] == "gemini-secret")
        #expect(partitioned.ephemeral["OPENROUTER_API_KEY"] == "openrouter-secret")
        #expect(partitioned.ephemeral["CUSTOM_AUTH_TOKEN"] == "custom-auth-secret")
        #expect(partitioned.ephemeral["CUSTOM_ACCESS_TOKEN"] == "custom-access-secret")
        #expect(partitioned.ephemeral["CUSTOM_CLIENT_SECRET"] == "custom-client-secret")

        let selected = partitioned.merged
        #expect(selected["CMUX_AGENT_HOOK_DELIVERY_ID"] == nil)
        #expect(selected["CMUX_SOCKET_CAPABILITY"] == nil)
        #expect(selected["CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP"] == nil)
        #expect(selected["UNRELATED_SECRET"] == nil)
    }
}
