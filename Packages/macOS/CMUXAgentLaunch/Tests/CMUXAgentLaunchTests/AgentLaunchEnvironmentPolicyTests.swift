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

    @Test(
        "Keeps a caller preload that only resembles the cmux location, and its following options",
        arguments: [
            "/opt/vendor/cmux/node-options/restore-node-options.cjs",
            "/Users/me/Code/cmux-fork/restore-node-options.cjs",
            "/srv/cmux/restore-node-options.cjs",
        ]
    )
    func keepsPreloadThatOnlyResemblesTheCmuxLocation(callerPreload: String) {
        // The trailing 4096 is the caller's here: nothing cmux-owned precedes it, so the
        // injected-heap-cap unwind must not consume it either.
        let nodeOptions = "--require=\(callerPreload) --max-old-space-size=4096 --trace-warnings"
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["NODE_OPTIONS": nodeOptions],
            kind: "claude"
        )

        #expect(selected == ["NODE_OPTIONS": nodeOptions])
    }

    @Test(
        "Drops a cmux preload written in any --require spelling, with its paired heap cap",
        arguments: [
            "--require=/tmp/cmux-claude-node-options/restore-node-options.cjs --max-old-space-size=4096",
            "--require /tmp/cmux-claude-node-options/restore-node-options.cjs --max-old-space-size 4096",
            "-r /tmp/cmux-claude-node-options/restore-node-options.cjs --max-old-space-size=4096",
            "-r=/tmp/cmux-claude-node-options/restore-node-options.cjs --max-old-space-size 4096",
        ]
    )
    func dropsPreloadInEverySpelling(injected: String) {
        // A persisted environment can carry either spelling, and a surviving dead preload is the
        // MODULE_NOT_FOUND crash this mechanism exists to prevent.
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["NODE_OPTIONS": "\(injected) --trace-warnings"],
            kind: "claude"
        )

        #expect(selected == ["NODE_OPTIONS": "--trace-warnings"])
    }

    @Test(
        "Drops a cmux preload whose path arrives wrapped in quotes",
        arguments: [
            "--require=\"/tmp/cmux-claude-node-options/restore-node-options.cjs\"",
            "--require \"/tmp/cmux-claude-node-options/restore-node-options.cjs\"",
        ]
    )
    func dropsQuotedPreload(injected: String) {
        // node consumes surrounding double quotes in NODE_OPTIONS, so an inherited value can
        // carry them around the path.
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["NODE_OPTIONS": "\(injected) --trace-warnings"],
            kind: "claude"
        )

        #expect(selected == ["NODE_OPTIONS": "--trace-warnings"])
    }

    @Test("Keeps a caller preload written in the space-separated form")
    func keepsCallerPreloadInSpaceForm() {
        let nodeOptions = "--require /opt/vendor/instrument.cjs --trace-warnings"
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["NODE_OPTIONS": nodeOptions],
            kind: "claude"
        )

        #expect(selected == ["NODE_OPTIONS": nodeOptions])
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
