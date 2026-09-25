import CMUXAgentLaunch
import Testing

@Suite("RovoDevHookConfig")
struct RovoDevHookConfigTests {
    /// The event set the app installs, shared by the round-trip tests below.
    ///
    /// Computed rather than stored: `RovoDevHookConfig.Event` is not `Sendable`,
    /// so a `static let` would be a concurrency-unsafe global under Swift 6.
    private static var events: [RovoDevHookConfig.Event] {
        [
            RovoDevHookConfig.Event(name: "on_complete", command: "cmux hooks rovodev stop"),
            RovoDevHookConfig.Event(name: "on_error", command: "cmux hooks rovodev stop"),
            RovoDevHookConfig.Event(name: "on_tool_permission", command: "cmux hooks rovodev prompt-submit"),
        ]
    }

    @Test("Install adds the root block and uninstall restores the original config")
    func installAddsRootBlockAndUninstallRestoresOriginalConfig() {
        let existing = """
        sessions:
          persistenceDir: /tmp/rovo

        """

        let installed = RovoDevHookConfig.installing(events: Self.events, in: existing)

        #expect(installed.contains("# cmux hooks rovodev begin"))
        #expect(installed.contains("eventHooks:"))
        #expect(installed.contains("  events:"))
        #expect(installed.contains("    - name: on_complete"))
        #expect(installed.contains("    - command: \"cmux hooks rovodev stop\""))
        #expect(RovoDevHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Install merges into existing events and is idempotent")
    func installMergesIntoExistingEventsAndIsIdempotent() {
        let existing = """
        eventHooks:
          events:
            - name: user_hook
              commands:
                - command: "echo user"

        """

        let installed = RovoDevHookConfig.installing(events: Self.events, in: existing)
        let reinstalled = RovoDevHookConfig.installing(events: Self.events, in: installed)

        #expect(reinstalled == installed)
        #expect(installed.contains("    # cmux hooks rovodev begin"))
        #expect(installed.contains("    - name: user_hook"))
        #expect(installed.contains("        - command: \"echo user\""))
        #expect(installed.contains("    - name: on_tool_permission"))
        #expect(RovoDevHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Install adds the events child when only the eventHooks root exists")
    func installAddsEventsChildWhenOnlyEventHooksRootExists() {
        let existing = """
        eventHooks:
          enabled: true

        """

        let installed = RovoDevHookConfig.installing(events: Self.events, in: existing)

        #expect(installed.contains("eventHooks:\n  # cmux hooks rovodev begin\n  events:"))
        #expect(installed.contains("  enabled: true"))
        #expect(RovoDevHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Install escapes command strings for YAML")
    func installEscapesCommandStringsForYaml() {
        let events = [
            RovoDevHookConfig.Event(
                name: "on_complete",
                command: "cmux hooks rovodev stop --message \"done\" \\ next\nline"
            ),
        ]

        let installed = RovoDevHookConfig.installing(events: events, in: "")

        #expect(installed.contains("command: \"cmux hooks rovodev stop --message \\\"done\\\" \\\\ next\\nline\""))
    }

    @Test("Uninstall leaves a dangling marked block untouched")
    func uninstallLeavesDanglingMarkedBlockUntouched() {
        let existing = """
        eventHooks:
          events:
            # cmux hooks rovodev begin
            - name: on_complete
              commands:
                - command: "cmux hooks rovodev stop"
        sessions:
          persistenceDir: /tmp/rovo

        """

        #expect(RovoDevHookConfig.uninstalling(from: existing) == existing)
    }

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

    @Test("Dangling cmux marker does not drop following YAML")
    func danglingMarkerDoesNotDropFollowingYAML() {
        let existing = """
        eventHooks:
          events:
            # cmux hooks rovodev begin
        sessions:
          persistenceDir: /tmp/rovo

        """

        let events = [
            RovoDevHookConfig.Event(
                name: "on_complete",
                command: "cmux hooks rovodev stop"
            ),
        ]
        let installed = RovoDevHookConfig.installing(events: events, in: existing)
        let uninstalled = RovoDevHookConfig.uninstalling(from: existing)

        #expect(installed.contains("sessions:\n  persistenceDir: /tmp/rovo"))
        #expect(uninstalled.contains("sessions:\n  persistenceDir: /tmp/rovo"))
    }
}
