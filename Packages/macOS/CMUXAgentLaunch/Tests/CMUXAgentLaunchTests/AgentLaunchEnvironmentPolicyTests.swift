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

    @Test("Preserves Claude secure storage config dir for Claude launchers without persisting secrets")
    func preservesClaudeSecureStorageConfigDirForClaudeLaunchersWithoutPersistingSecrets() {
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: [
                "AMP_API_KEY": "amp-secret-should-not-persist",
                "ANTHROPIC_AUTH_TOKEN": "anthropic-secret-should-not-persist",
                "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/claude-secure-storage",
            ],
            kind: "claude"
        )

        #expect(selected["CLAUDE_CONFIG_DIR"] == "/tmp/claude-config")
        #expect(selected["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == "/tmp/claude-secure-storage")
        #expect(selected["AMP_API_KEY"] == nil)
        #expect(selected["ANTHROPIC_AUTH_TOKEN"] == nil)

        let claudeTeamsSelected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/claude-teams-secure-storage"],
            kind: "claudeTeams"
        )
        #expect(claudeTeamsSelected["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == "/tmp/claude-teams-secure-storage")

        let codexSelected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/claude-secure-storage"],
            kind: "codex"
        )
        #expect(codexSelected["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
    }

    @Test("Records absent Claude secure storage config dir for Claude launch capture")
    func recordsAbsentClaudeSecureStorageConfigDirForClaudeLaunchCapture() {
        let policy = AgentLaunchEnvironmentPolicy()
        let clearKeysKey = AgentLaunchEnvironmentPolicy.claudeAuthSelectionClearEnvironmentKeysKey

        let present = policy.selectedLaunchEnvironment(
            from: [
                clearKeysKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR",
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/claude-secure-storage",
            ],
            kind: "claude"
        )
        #expect(present["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == "/tmp/claude-secure-storage")
        #expect(present[clearKeysKey] == nil)

        let absent = policy.selectedLaunchEnvironment(
            from: [
                clearKeysKey: "UNSUPPORTED_KEY,CLAUDE_SECURESTORAGE_CONFIG_DIR",
                "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
            ],
            kind: "claude"
        )
        #expect(absent["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
        #expect(absent[clearKeysKey] == "CLAUDE_SECURESTORAGE_CONFIG_DIR")

        let claudeTeamsAbsent = policy.selectedLaunchEnvironment(from: [:], kind: "claudeTeams")
        #expect(claudeTeamsAbsent[clearKeysKey] == "CLAUDE_SECURESTORAGE_CONFIG_DIR")

        let codexAbsent = policy.selectedLaunchEnvironment(from: [:], kind: "codex")
        #expect(codexAbsent[clearKeysKey] == nil)

        let genericSelected = policy.selectedEnvironment(
            from: [
                clearKeysKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR",
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/claude-secure-storage",
            ]
        )
        #expect(genericSelected[clearKeysKey] == nil)
        #expect(genericSelected["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
    }

    @Test("Restore transport keeps Pi PATH without crossing secrets")
    func restoreTransportKeepsPiPathWithoutSecrets() {
        let selected = AgentLaunchEnvironmentPolicy().selectedRestoreEnvironment(
            from: [
                "PATH": "/nix/store/pi/bin:/usr/bin",
                "PI_CONFIG_DIR": ".custom-pi",
                "OPENAI_API_KEY": "secret-should-not-cross-socket",
            ],
            kind: "pi"
        )

        #expect(selected == [
            "PATH": "/nix/store/pi/bin:/usr/bin",
            "PI_CONFIG_DIR": ".custom-pi",
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
}
