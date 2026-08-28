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

    @Test(
        "Restore transport keeps Pi-family PATH without crossing secrets",
        arguments: ["pi", "omp"]
    )
    func restoreTransportKeepsPiFamilyPathWithoutSecrets(kind: String) {
        let selected = AgentLaunchEnvironmentPolicy().selectedRestoreEnvironment(
            from: [
                "PATH": "/nix/store/pi/bin:/usr/bin",
                "PI_CONFIG_DIR": ".custom-pi",
                "OPENAI_API_KEY": "secret-should-not-cross-socket",
            ],
            kind: kind
        )

        #expect(selected == [
            "PATH": "/nix/store/pi/bin:/usr/bin",
            "PI_CONFIG_DIR": ".custom-pi",
        ])
    }

    @Test(
        "Restore records retain only trusted Subrouter Codex routing metadata",
        arguments: ["sr", "subrouter", "cx"]
    )
    func restoreRecordsRetainTrustedSubrouterCodexMetadata(command: String) {
        let policy = AgentLaunchEnvironmentPolicy()
        let selected = policy.selectedRestoreRecordEnvironment(
            from: [
                "OPENAI_API_KEY": "secret-should-not-cross-socket",
                "SUBROUTER_CODEX_ACCOUNT_ID": "team-codex-1",
                "SUBROUTER_CODEX_BASE_URL": "https://router.example.test/v1",
                "SUBROUTER_CODEX_RESUME_COMMAND": "\(command) codex resume",
                "SUBROUTER_CODEX_SERVER": "team",
                "SUBROUTER_CODEX_USER_EMAIL": "operator@example.test",
            ],
            kind: "codex",
            launcher: "codex",
            arguments: ["codex", "-c", "model_provider=subrouter"]
        )

        #expect(selected == [
            "SUBROUTER_CODEX_ACCOUNT_ID": "team-codex-1",
            "SUBROUTER_CODEX_BASE_URL": "https://router.example.test/v1",
            "SUBROUTER_CODEX_RESUME_COMMAND": "\(command) codex resume",
            "SUBROUTER_CODEX_SERVER": "team",
            "SUBROUTER_CODEX_USER_EMAIL": "operator@example.test",
        ])
        #expect(
            policy.selectedRestoreEnvironment(from: selected, kind: "codex")[
                "SUBROUTER_CODEX_RESUME_COMMAND"
            ] == nil
        )
    }

    @Test("Restore records reject unsafe Subrouter routing metadata")
    func restoreRecordsRejectUnsafeSubrouterRoutingMetadata() {
        let selected = AgentLaunchEnvironmentPolicy().selectedRestoreRecordEnvironment(
            from: [
                "SUBROUTER_CODEX_ACCOUNT_ID": "team\ncodex",
                "SUBROUTER_CODEX_BASE_URL": "https://user:secret@router.example.test/v1",
                "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                "SUBROUTER_CODEX_SERVER": "team\nstaging",
                "SUBROUTER_CODEX_USER_EMAIL": "operator@example.test\nX-Injected: yes",
            ],
            kind: "codex",
            launcher: "codex",
            arguments: ["codex", "-c", "model_provider=subrouter"]
        )

        #expect(selected == [
            "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
        ])
    }

    @Test("Restore records reject unproved or noncanonical Subrouter metadata")
    func restoreRecordsRejectUntrustedSubrouterMetadata() {
        let policy = AgentLaunchEnvironmentPolicy()

        #expect(policy.selectedRestoreRecordEnvironment(
            from: ["SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume"],
            kind: "codex",
            launcher: "codex",
            arguments: ["codex"]
        ).isEmpty)
        #expect(policy.selectedRestoreRecordEnvironment(
            from: ["SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume; echo unsafe"],
            kind: "codex",
            launcher: "codex",
            arguments: ["codex", "-c", "model_provider=subrouter"]
        ).isEmpty)
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
