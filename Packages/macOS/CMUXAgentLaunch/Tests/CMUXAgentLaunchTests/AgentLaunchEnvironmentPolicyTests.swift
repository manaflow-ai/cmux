import CMUXAgentLaunch
import Testing

@Suite("AgentLaunchEnvironmentPolicy")
struct AgentLaunchEnvironmentPolicyTests {
    @Test(
        "Drops the cmux NODE_OPTIONS restore preload from every directory it has shipped in",
        arguments: [
            "/var/folders/ab/T/cmux-claude-node-options/restore-node-options.cjs",
            "/tmp/cmux-claude-node-options-9f3a/restore-node-options.cjs",
            "/Users/someone/.local/state/cmux/node-options/restore-node-options.cjs",
        ]
    )
    func dropsCmuxNodeOptionsRestorePreload(modulePath: String) {
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["NODE_OPTIONS": "--require=\(modulePath) --max-old-space-size=4096 --trace-warnings"],
            kind: "claude"
        )

        #expect(selected == ["NODE_OPTIONS": "--trace-warnings"])
    }

    @Test("Keeps a user's own preload that merely shares the module name")
    func keepsUnrelatedPreloadWithTheSameModuleName() {
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["NODE_OPTIONS": "--require=/opt/vendor/restore-node-options.cjs --max-old-space-size=4096"],
            kind: "claude"
        )

        #expect(selected == ["NODE_OPTIONS": "--require=/opt/vendor/restore-node-options.cjs --max-old-space-size=4096"])
    }

    @Test("Keeps a heap cap the caller chose while dropping the one cmux injected")
    func keepsCallerHeapCapAndDropsInjectedOne() {
        let modulePath = "/Users/someone/.local/state/cmux/node-options/restore-node-options.cjs"
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["NODE_OPTIONS": "--require=\(modulePath) --max-old-space-size=4096 --max-old-space-size=2048"],
            kind: "claude"
        )

        #expect(selected == ["NODE_OPTIONS": "--max-old-space-size=2048"])
    }

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
}
