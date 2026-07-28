import CMUXAgentLaunch
import Testing

@Suite("Managed launcher non-launch classification")
struct ManagedLauncherNonLaunchTests {
    @Test("OMO preserves documented management commands")
    func omoManagementCommands() {
        for command in [
            "agent", "auth", "completion", "db", "debug", "mcp", "models",
            "plugin", "providers", "stats", "uninstall", "upgrade",
        ] {
            #expect(AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: [command]))
        }
        #expect(AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: ["--log-level", "WARN", "models"]))
        #expect(AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: ["--help"]))
        #expect(AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: ["-v"]))
    }

    @Test("OMO rejects sessions, unknown commands, and command-shaped values")
    func omoLaunches() {
        for args in [
            ["session"],
            ["run", "hello"],
            ["unknown-command"],
            ["--session", "session-id"],
            ["--model", "--version"],
            ["--", "--version"],
            ["some-project"],
        ] {
            #expect(!AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: args))
        }
    }

    @Test("OMX preserves documented management commands")
    func omxManagementCommands() {
        for command in [
            "agents", "agents-init", "auth", "deepinit", "doctor", "help",
            "list", "setup", "status", "uninstall", "update", "version",
        ] {
            #expect(AgentLaunchSanitizer.omxLaunchIsNonLaunch(args: [command]))
        }
        #expect(AgentLaunchSanitizer.omxLaunchIsNonLaunch(args: ["--scope", "project", "setup"]))
        #expect(AgentLaunchSanitizer.omxLaunchIsNonLaunch(args: ["--help"]))
        #expect(AgentLaunchSanitizer.omxLaunchIsNonLaunch(args: ["--version"]))
    }

    @Test("OMX rejects sessions, unknown commands, and command-shaped values")
    func omxLaunches() {
        for args in [
            ["session"],
            ["resume"],
            ["team", "status", "demo"],
            ["unknown-command"],
            ["--scope", "--version"],
            ["--", "--version"],
            ["--high"],
        ] {
            #expect(!AgentLaunchSanitizer.omxLaunchIsNonLaunch(args: args))
        }
    }
}
