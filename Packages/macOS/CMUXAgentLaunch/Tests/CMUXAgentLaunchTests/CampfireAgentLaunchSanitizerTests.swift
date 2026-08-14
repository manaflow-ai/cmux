import CMUXAgentLaunch
import Testing

@Suite("Campfire agent launch sanitizer")
struct CampfireAgentLaunchSanitizerTests {
    @Test("Drops Campfire session selectors, invite URLs, and joiner flags")
    func dropsCampfireSessionSelectorsInviteUrlsAndJoinerFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "campfire",
                    "--session",
                    "old-session",
                    "--relay",
                    "wss://relay.example/ws",
                    "--model",
                    "anthropic/claude-sonnet-4-5",
                    "initial prompt should not replay",
                ],
                launcher: "campfire",
                fallbackKind: "campfire"
            ) == [
                "campfire",
                "--relay",
                "wss://relay.example/ws",
                "--model",
                "anthropic/claude-sonnet-4-5",
            ]
        )
        // An invite URL is a lobby capability token. It must never be
        // persisted or replayed, in any argv position.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "campfire",
                    "https://relay.example/j/6bbb595d#lk=secret-lobby-token",
                    "--join-as",
                    "alice",
                ],
                launcher: "campfire",
                fallbackKind: "campfire"
            ) == ["campfire"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["campfire", "--join-as", "alice", "--theme", "dark"],
                launcher: "campfire",
                fallbackKind: "campfire"
            ) == ["campfire", "--theme", "dark"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "campfire",
                    "--join",
                    "https://relay.example/j/6bbb595d#lk=secret-lobby-token",
                    "--theme",
                    "dark",
                ],
                launcher: "campfire",
                fallbackKind: "campfire"
            ) == ["campfire", "--theme", "dark"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "campfire",
                    "--join=https://relay.example/j/6bbb595d#lk=secret-lobby-token",
                    "--theme",
                    "dark",
                ],
                launcher: "campfire",
                fallbackKind: "campfire"
            ) == ["campfire", "--theme", "dark"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["campfire", "--session=old-session", "--relay=wss://relay.example/ws"],
                launcher: "campfire",
                fallbackKind: "campfire"
            ) == ["campfire", "--relay=wss://relay.example/ws"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["campfire", "init", "--auto-exit"],
                launcher: "campfire",
                fallbackKind: "campfire"
            ) == nil
        )
    }
}
