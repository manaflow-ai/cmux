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

    @Test("Keeps the Prime Agent config roots for resumes")
    func keepsPrimeAgentConfigDirectory() {
        let selected = AgentLaunchEnvironmentPolicy().selectedRestoreEnvironment(
            from: [
                "PRIME_AGENT_CODING_AGENT_DIR": "/tmp/prime-agent",
                "PRIME_AGENT_CODING_AGENT_SESSION_DIR": "/tmp/prime-sessions",
                "OPENAI_API_KEY": "secret-should-not-cross-restore",
            ],
            kind: "prime-agent"
        )

        #expect(selected == [
            "PRIME_AGENT_CODING_AGENT_DIR": "/tmp/prime-agent",
            "PRIME_AGENT_CODING_AGENT_SESSION_DIR": "/tmp/prime-sessions",
        ])
    }
}
