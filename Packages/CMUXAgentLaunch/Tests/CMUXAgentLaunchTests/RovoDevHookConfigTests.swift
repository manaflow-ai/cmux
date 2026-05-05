import CMUXAgentLaunch
import Testing

@Suite("RovoDevHookConfig")
struct RovoDevHookConfigTests {
    @Test("Installs into direct eventHooks events child only")
    func installsIntoDirectEventHooksEventsChildOnly() {
        let existing = """
        eventHooks:
          nested:
            events:
              - name: user_hook
                commands:
                  - command: "echo user"

        """

        let events = [
            RovoDevHookConfig.Event(
                name: "on_complete",
                command: "cmux hooks rovodev stop"
            ),
        ]
        let installed = RovoDevHookConfig.installing(events: events, in: existing)

        #expect(installed.contains("eventHooks:\n  # cmux hooks rovodev begin\n  events:"))
        #expect(installed.contains("    events:\n      - name: user_hook"))
        #expect(RovoDevHookConfig.uninstalling(from: installed) == existing)
    }
}
