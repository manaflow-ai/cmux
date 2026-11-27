import CMUXAgentLaunch
import Testing

@Suite("Claude remote control restore")
struct ClaudeRemoteControlRestoreTests {
    private let executable = "/opt/homebrew/bin/claude"

    @Test("Preserves a split remote-control name")
    func preservesSplitName() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [executable, "--remote-control", "my-phone"],
                launcher: "",
                fallbackKind: "claude"
            ) == [executable, "--remote-control", "my-phone"]
        )
    }

    @Test("Preserves a split remote-control name before later options")
    func preservesSplitNameBeforeLaterOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [executable, "--remote-control", "my-phone", "--model", "sonnet"],
                launcher: "",
                fallbackKind: "claude"
            ) == [executable, "--remote-control", "my-phone", "--model", "sonnet"]
        )
    }

    @Test("Preserves an equals-form remote-control name")
    func preservesEqualsFormName() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [executable, "--remote-control=my-phone", "--model", "sonnet"],
                launcher: "",
                fallbackKind: "claude"
            ) == [executable, "--remote-control=my-phone", "--model", "sonnet"]
        )
    }
}
