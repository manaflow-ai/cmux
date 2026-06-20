import CMUXAgentLaunch
import Testing

@Suite("AgentLaunchSanitizer variadic channels")
struct AgentLaunchSanitizerVariadicChannelsTests {
    @Test("Claude multi-value channels flag does not truncate downstream flags")
    func claudeMultiValueChannelsFlagDoesNotTruncateDownstreamFlags() {
        // --dangerously-load-development-channels accepts multiple server:<name>
        // values. The sanitizer must consume them all as variadic values so the
        // flags that follow (--agents, --agent, --debug-file,
        // --dangerously-skip-permissions) survive into the resume argv instead of
        // being silently dropped at the first stray positional.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--mcp-config",
                    "/Users/me/Code/.mcp.json",
                    "--dangerously-load-development-channels",
                    "server:slack-bus",
                    "server:runtime-bus",
                    "server:peer-bus",
                    "--debug-file",
                    "/tmp/cc-debug.log",
                    "--agents",
                    #"{"name":{}}"#,
                    "--dangerously-skip-permissions",
                    "--agent",
                    "build-orchestrator",
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--mcp-config",
                "/Users/me/Code/.mcp.json",
                "--dangerously-load-development-channels",
                "server:slack-bus",
                "server:runtime-bus",
                "server:peer-bus",
                "--debug-file",
                "/tmp/cc-debug.log",
                "--agents",
                #"{"name":{}}"#,
                "--dangerously-skip-permissions",
                "--agent",
                "build-orchestrator",
            ]
        )
    }

    @Test("Claude variadic channels flag still drops a trailing startup prompt")
    func claudeVariadicChannelsFlagStillDropsTrailingPrompt() {
        // The channel flag's values are whitespace-free `server:<name>` specs, so
        // variadic consumption must stop at a shell-quoted startup prompt. The
        // prompt is a positional and must never be replayed into the resume argv.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--dangerously-load-development-channels",
                    "server:dev",
                    "server:peer",
                    "initial prompt should not replay",
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--dangerously-load-development-channels",
                "server:dev",
                "server:peer",
            ]
        )
    }

    @Test("Claude variadic channels flag drops a single-word startup prompt")
    func claudeVariadicChannelsFlagDropsSingleWordPrompt() {
        // A startup prompt can be a single whitespace-free word. It is not a
        // `scheme:name` channel spec, so variadic consumption must stop at it and
        // the sanitizer must drop it. Flags that precede the trailing prompt
        // (the shape of a real cold-launch argv) are preserved.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--model",
                    "sonnet",
                    "--dangerously-load-development-channels",
                    "server:dev",
                    "fix",
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--model",
                "sonnet",
                "--dangerously-load-development-channels",
                "server:dev",
            ]
        )
    }

    @Test("Claude variadic channels flag drops a colon-shaped startup prompt")
    func claudeVariadicChannelsFlagDropsColonShapedPrompt() {
        // A startup prompt token can be colon-shaped (e.g. `fix:login`) yet is not
        // a `server:<name>` channel value, so it must stop the variadic scan and
        // be dropped instead of being replayed as a development-channel argument.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--model",
                    "sonnet",
                    "--dangerously-load-development-channels",
                    "server:dev",
                    "fix:login",
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--model",
                "sonnet",
                "--dangerously-load-development-channels",
                "server:dev",
            ]
        )
    }

    @Test("Claude channels flag with no server: value is dropped, not left bare")
    func claudeChannelsFlagWithNoValueIsDropped() {
        // If the only token after the flag is not a server: channel (a malformed
        // or future-scheme value, or a bare prompt), the flag consumes nothing.
        // It must be dropped entirely — emitting a value-requiring flag with no
        // value would make the resumed launch fail to parse.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--model",
                    "sonnet",
                    "--dangerously-load-development-channels",
                    "client:unknown",
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--model",
                "sonnet",
            ]
        )
    }

    @Test("Claude channels flag preserves mixed server: and plugin: channel values")
    func claudeChannelsFlagPreservesPluginChannels() {
        // Claude Code accepts both `server:<name>` and `plugin:<name>@<marketplace>`
        // tagged channels. Both tags must be consumed as channel values so the
        // following flags survive, while a trailing prompt is still dropped.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--dangerously-load-development-channels",
                    "server:slack-bus",
                    "plugin:foo@local",
                    "--debug-file",
                    "/tmp/log",
                    "initial prompt should not replay",
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--dangerously-load-development-channels",
                "server:slack-bus",
                "plugin:foo@local",
                "--debug-file",
                "/tmp/log",
            ]
        )
    }
}
