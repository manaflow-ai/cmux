import CMUXAgentLaunch
import Testing

@Suite("VibeHookConfig")
struct VibeHookConfigTests {
    @Test("Installs hooks into empty config")
    func installsHooksIntoEmptyConfig() {
        let events = [
            VibeHookConfig.Event(
                name: "cmux-stop",
                type: "post_agent",
                command: "cmux hooks vibe stop",
                timeout: 60
            ),
            VibeHookConfig.Event(
                name: "cmux-pre-tool",
                type: "pre_tool",
                command: "cmux hooks feed --source vibe --event pre_tool",
                timeout: 120
            ),
        ]

        let installed = VibeHookConfig().installing(events: events, in: "")

        #expect(installed == """
        # cmux-vibe-hooks-8a3f5c2d-1b4e-4f7a-9d6c-2e8b1a3f5c7d begin
        [[hooks]]
        name = "cmux-stop"
        type = "post_agent"
        command = "cmux hooks vibe stop"
        timeout = 60.0

        [[hooks]]
        name = "cmux-pre-tool"
        type = "pre_tool"
        command = "cmux hooks feed --source vibe --event pre_tool"
        timeout = 120.0

        # cmux-vibe-hooks-8a3f5c2d-1b4e-4f7a-9d6c-2e8b1a3f5c7d end

        """)
    }

    @Test("Install preserves existing user content with separating blank line")
    func installPreservesExistingUserContentWithSeparatingBlankLine() {
        let existing = """
        active_model = "mistral-medium-3.5"
        theme = "auto"

        """
        let events = [
            VibeHookConfig.Event(name: "cmux-stop", type: "post_agent", command: "cmux hooks vibe stop", timeout: 60),
        ]

        let installed = VibeHookConfig().installing(events: events, in: existing)

        #expect(installed == """
        active_model = "mistral-medium-3.5"
        theme = "auto"

        # cmux-vibe-hooks-8a3f5c2d-1b4e-4f7a-9d6c-2e8b1a3f5c7d begin
        [[hooks]]
        name = "cmux-stop"
        type = "post_agent"
        command = "cmux hooks vibe stop"
        timeout = 60.0

        # cmux-vibe-hooks-8a3f5c2d-1b4e-4f7a-9d6c-2e8b1a3f5c7d end

        """)
    }

    @Test("Install is idempotent")
    func installIsIdempotent() {
        let existing = "active_model = \"mistral-medium-3.5\"\n"
        let events = [
            VibeHookConfig.Event(name: "cmux-stop", type: "post_agent", command: "cmux hooks vibe stop", timeout: 60),
        ]

        let installed = VibeHookConfig().installing(events: events, in: existing)

        #expect(VibeHookConfig().installing(events: events, in: installed) == installed)
    }

    @Test("Reinstall replaces stale cmux block")
    func reinstallReplacesStaleCmuxBlock() {
        let stale = VibeHookConfig().installing(
            events: [VibeHookConfig.Event(name: "cmux-stop", type: "post_agent", command: "cmux hooks vibe stop", timeout: 60)],
            in: "active_model = \"mistral-medium-3.5\"\n"
        )

        let reinstalled = VibeHookConfig().installing(
            events: [VibeHookConfig.Event(name: "cmux-stop", type: "post_agent", command: "cmux hooks vibe stop", timeout: 30)],
            in: stale
        )

        #expect(reinstalled.components(separatedBy: "# cmux-vibe-hooks-8a3f5c2d-1b4e-4f7a-9d6c-2e8b1a3f5c7d begin").count == 2)
        #expect(reinstalled.contains("timeout = 30.0"))
        #expect(!reinstalled.contains("timeout = 60.0"))
    }

    @Test("Install uninstall round trip restores normalized existing content")
    func installUninstallRoundTripRestoresNormalizedExistingContent() {
        let existing = "active_model = \"mistral-medium-3.5\"\ntheme = \"auto\"\n\n"
        let events = [
            VibeHookConfig.Event(name: "cmux-stop", type: "post_agent", command: "cmux hooks vibe stop", timeout: 60),
        ]

        let installed = VibeHookConfig().installing(events: events, in: existing)

        #expect(VibeHookConfig().uninstalling(from: installed) == existing)
    }

    @Test("Uninstall without cmux block leaves content unchanged")
    func uninstallWithoutCmuxBlockLeavesContentUnchanged() {
        let existing = """
        active_model = "mistral-medium-3.5"
        theme = "auto"

        """

        #expect(VibeHookConfig().uninstalling(from: existing) == existing)
    }

    @Test("Detects whether a config carries a cmux block")
    func detectsWhetherConfigCarriesCmuxBlock() {
        let userOnly = """
        active_model = "mistral-medium-3.5"

        [[hooks]]
        name = "my-hook"
        type = "post_agent"
        command = "echo hello"

        """
        let installed = VibeHookConfig().installing(
            events: [
                VibeHookConfig.Event(
                    name: "cmux-stop",
                    type: "post_agent",
                    command: "cmux hooks vibe stop",
                    timeout: 60
                ),
            ],
            in: userOnly
        )

        #expect(!VibeHookConfig().containsCmuxBlock(in: ""))
        #expect(!VibeHookConfig().containsCmuxBlock(in: userOnly))
        #expect(VibeHookConfig().containsCmuxBlock(in: installed))
        #expect(!VibeHookConfig().containsCmuxBlock(
            in: VibeHookConfig().uninstalling(from: installed)
        ))
    }

    @Test("Uninstall removes orphaned begin marker without dropping following TOML")
    func uninstallRemovesOrphanedBeginMarkerWithoutDroppingFollowingTOML() {
        let existing = """
        active_model = "mistral-medium-3.5"
        # cmux-vibe-hooks-8a3f5c2d-1b4e-4f7a-9d6c-2e8b1a3f5c7d begin
        theme = "auto"

        """

        #expect(VibeHookConfig().uninstalling(from: existing) == """
        active_model = "mistral-medium-3.5"
        theme = "auto"

        """)
    }

    @Test("Escapes TOML basic string content")
    func escapesTOMLBasicStringContent() {
        let events = [
            VibeHookConfig.Event(
                name: "cmux-stop",
                type: "post_agent",
                command: "cmux hooks \"vibe\" \\\tstop",
                timeout: 60
            ),
        ]

        let installed = VibeHookConfig().installing(events: events, in: "")

        #expect(installed.contains(#"command = "cmux hooks \"vibe\" \\\tstop""#))
    }

    @Test("Handles CRLF line endings")
    func handlesCRLFLineEndings() {
        let eventsV1 = [
            VibeHookConfig.Event(name: "cmux-stop", type: "post_agent", command: "cmux hooks vibe stop", timeout: 60),
        ]
        let crlfExisting = "active_model = \"mistral-medium-3.5\"\r\ntheme = \"auto\"\r\n"

        #expect(
            VibeHookConfig().uninstalling(from: crlfExisting)
                == "active_model = \"mistral-medium-3.5\"\ntheme = \"auto\"\n"
        )

        let installed = VibeHookConfig().installing(events: eventsV1, in: crlfExisting)
        #expect(VibeHookConfig().containsCmuxBlock(in: installed))

        let crlfInstalled = installed.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(VibeHookConfig().containsCmuxBlock(in: crlfInstalled))

        let eventsV2 = [
            VibeHookConfig.Event(name: "cmux-stop", type: "post_agent", command: "cmux hooks vibe stop", timeout: 30),
        ]
        let refreshed = VibeHookConfig().installing(events: eventsV2, in: crlfInstalled)
        #expect(refreshed.components(separatedBy: "# cmux-vibe-hooks-8a3f5c2d-1b4e-4f7a-9d6c-2e8b1a3f5c7d begin").count == 2)
        #expect(refreshed.contains("timeout = 30.0"))
        #expect(!refreshed.contains("timeout = 60.0"))

        #expect(
            VibeHookConfig().uninstalling(from: crlfInstalled)
                == VibeHookConfig().uninstalling(from: installed)
        )
    }
}
