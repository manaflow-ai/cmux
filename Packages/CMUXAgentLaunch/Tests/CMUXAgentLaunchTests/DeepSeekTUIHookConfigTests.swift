import CMUXAgentLaunch
import Foundation
import Testing

@Suite("DeepSeekTUIHookConfig")
struct DeepSeekTUIHookConfigTests {
    @Test("Installs hook array without duplicating an existing hooks table")
    func installsHookArrayWithoutDuplicatingExistingHooksTable() {
        let existing = """
        default_text_model = "deepseek-v4"

        [hooks]
        enabled = true

        [[hooks.hooks]]
        event = "session_start"
        command = "echo user"

        """

        let installed = DeepSeekTUIHookConfig.installing(
            events: [
                DeepSeekTUIHookConfig.Event(
                    name: "message_submit",
                    command: #"cmux hooks deepseek-tui prompt-submit --note "quoted""#
                ),
            ],
            in: existing
        )

        #expect(installed.components(separatedBy: "[hooks]").count - 1 == 1)
        #expect(installed.contains("# cmux hooks deepseek-tui begin"))
        #expect(installed.contains(#"event = "message_submit""#))
        #expect(installed.contains(#"command = "cmux hooks deepseek-tui prompt-submit --note \"quoted\"""#))
        #expect(DeepSeekTUIHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Creates hooks table when missing and reinstalls idempotently")
    func createsHooksTableWhenMissingAndReinstallsIdempotently() {
        let events = [
            DeepSeekTUIHookConfig.Event(
                name: "session_start",
                command: "cmux hooks deepseek-tui session-start"
            ),
        ]
        let installed = DeepSeekTUIHookConfig.installing(events: events, in: "")
        let reinstalled = DeepSeekTUIHookConfig.installing(events: events, in: installed)

        #expect(installed == reinstalled)
        #expect(installed.contains("[hooks]\nenabled = true"))
        #expect(DeepSeekTUIHookConfig.uninstalling(from: installed) == "[hooks]\nenabled = true\n")
    }

    @Test("Enables an existing hooks table")
    func enablesExistingHooksTable() {
        let installed = DeepSeekTUIHookConfig.installing(
            events: [
                DeepSeekTUIHookConfig.Event(
                    name: "session_end",
                    command: "cmux hooks deepseek-tui stop"
                ),
            ],
            in: """
            [hooks]
            enabled = false

            [[hooks.hooks]]
            event = "session_start"
            command = "echo user"

            """
        )

        #expect(installed.contains("[hooks]\nenabled = true"))
        #expect(!installed.contains("enabled = false"))
        #expect(installed.contains(#"event = "session_end""#))
    }
}
