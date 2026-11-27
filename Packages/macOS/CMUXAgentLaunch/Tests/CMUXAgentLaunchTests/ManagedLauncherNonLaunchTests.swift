import CMUXAgentLaunch
import Testing

@Suite("Managed launcher non-launch classification")
struct ManagedLauncherNonLaunchTests {
    private let classifier = AgentLaunchInvocationClassifier()

    @Test("Codex Teams recognizes nested informational flags without crossing --")
    func codexTeamsInformationalInvocations() {
        for args in [
            ["--help"],
            ["help"],
            ["help", "resume"],
            ["resume", "--help"],
            ["resume", "session-id", "--version"],
            ["exec", "review", "-h"],
            ["mcp", "list", "-V"],
        ] {
            #expect(
                classifier.codexTeamsLaunchIsInformational(args: args),
                "Codex Teams input \(args) must stay informational"
            )
        }
        for args in [
            [],
            ["resume"],
            ["exec", "prompt containing --help"],
            ["resume", "--", "--help"],
            ["--", "help"],
            ["--model=--help", "resume"],
        ] {
            #expect(
                !classifier.codexTeamsLaunchIsInformational(args: args),
                "Codex Teams input \(args) must stay launch-capable"
            )
        }
    }

    @Test("OMO preserves documented management commands")
    func omoManagementCommands() {
        for command in [
            "agent", "auth", "completion", "db", "debug", "mcp", "models",
            "export", "import", "plugin", "plug", "providers", "stats", "uninstall", "upgrade",
        ] {
            #expect(
                classifier.omoLaunchIsNonLaunch(args: [command]),
                "OMO command \(command) must stay non-launch"
            )
        }
        #expect(classifier.omoLaunchIsNonLaunch(args: ["session", "list"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["session", "delete", "session-id"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["github", "install"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["session", "--log-level", "WARN", "list"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["github", "--log-level=ERROR", "install"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["session", "--help"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["session", "run", "--help"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["run", "--help"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["run", "message", "--version"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["run", "--log-level", "WARN", "--help"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--log-level", "WARN", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--mdns", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--port", "4096", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--hostname=127.0.0.1", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--mdns-domain", "local", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--cors", "https://example.com", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--help"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["-v"]))
    }

    @Test("OMO rejects sessions, unknown commands, and command-shaped values")
    func omoLaunches() {
        for args in [
            ["acp"],
            ["serve"],
            ["web"],
            ["session"],
            ["session", "run"],
            ["session", "--", "--help"],
            ["session", "--", "list"],
            ["session", "--unknown-option", "list"],
            ["github", "--log-level"],
            ["github", "run"],
            ["run", "hello"],
            ["run", "--", "--help"],
            ["run", "--log-level", "--help"],
            ["run", "--unknown-option", "--help"],
            ["unknown-command"],
            ["--session", "session-id"],
            ["--model", "--version"],
            ["--port", "models"],
            ["--hostname", "--version"],
            ["--mdns-domain"],
            ["--cors"],
            ["--mdns", "run", "hello"],
            ["--", "--version"],
            ["some-project"],
        ] {
            #expect(
                !classifier.omoLaunchIsNonLaunch(args: args),
                "OMO input \(args) must stay launch-capable"
            )
        }
    }

    @Test("OMC preserves commands that do not start an agent or team")
    func omcManagementCommands() {
        for command in [
            "ask", "capabilities", "config", "config-notify-profile",
            "config-stop-callback", "doctor", "help", "info", "install",
            "postinstall", "session", "setup", "teleport", "test-prompt",
            "update", "update-reconcile", "version",
        ] {
            #expect(
                classifier.omcLaunchIsNonLaunch(args: [command]),
                "OMC command \(command) must stay non-launch"
            )
        }
        #expect(classifier.omcLaunchIsNonLaunch(args: ["--help"]))
        #expect(classifier.omcLaunchIsNonLaunch(args: ["--version"]))
        #expect(classifier.omcLaunchIsNonLaunch(args: ["team", "api", "claim-task"]))
        #expect(classifier.omcLaunchIsNonLaunch(args: ["team", "status", "demo"]))
        #expect(classifier.omcLaunchIsNonLaunch(args: ["team", "shutdown", "demo"]))
        #expect(classifier.omcLaunchIsNonLaunch(args: ["team", "--help"]))
        #expect(classifier.omcLaunchIsNonLaunch(args: ["team", "-h"]))
        #expect(classifier.omcLaunchIsNonLaunch(args: ["team", "resume", "--help"]))
    }

    @Test("OMC rejects agent and team launch commands")
    func omcLaunches() {
        for args in [
            [],
            ["launch"],
            ["interop"],
            ["team"],
            ["team", "resume"],
            ["team", "1:codex", "review this"],
            ["autoresearch"],
            ["ralphthon"],
            ["ultragoal"],
            ["start a team"],
            ["--", "version"],
        ] {
            #expect(
                !classifier.omcLaunchIsNonLaunch(args: args),
                "OMC input \(args) must stay launch-capable"
            )
        }
    }

    @Test("OMX preserves documented management commands")
    func omxManagementCommands() {
        for command in [
            "agents", "agents-init", "ask", "auth", "cancel", "capabilities", "deepinit",
            "doctor", "explore", "help", "hooks", "hud", "list", "reasoning",
            "session", "setup", "sparkshell", "status", "tmux-hook", "uninstall", "update", "version",
        ] {
            #expect(
                classifier.omxLaunchIsNonLaunch(args: [command]),
                "OMX command \(command) must stay non-launch"
            )
        }
        #expect(classifier.omxLaunchIsNonLaunch(args: ["--help"]))
        #expect(classifier.omxLaunchIsNonLaunch(args: ["--version"]))
        #expect(classifier.omxLaunchIsNonLaunch(args: ["team", "api", "claim-task"]))
        #expect(classifier.omxLaunchIsNonLaunch(args: ["team", "status", "demo"]))
        #expect(classifier.omxLaunchIsNonLaunch(args: ["team", "shutdown", "demo"]))
        #expect(classifier.omxLaunchIsNonLaunch(args: ["team", "--help"]))
        #expect(classifier.omxLaunchIsNonLaunch(args: ["team", "-h"]))
        #expect(classifier.omxLaunchIsNonLaunch(args: ["team", "resume", "--help"]))
    }

    @Test("OMX rejects sessions, unknown commands, and command-shaped values")
    func omxLaunches() {
        for args in [
            ["resume"],
            ["team"],
            ["team", "resume"],
            ["unknown-command"],
            ["--scope", "project", "setup"],
            ["--scope", "project", "ask"],
            ["--scope", "--version"],
            ["--", "--version"],
            ["--high"],
        ] {
            #expect(
                !classifier.omxLaunchIsNonLaunch(args: args),
                "OMX input \(args) must stay launch-capable"
            )
        }
    }
}
