import Testing
@testable import CmuxCloud

/// `CloudGuestDisplayScript` is main-actor isolated, so its tests run there too.
@MainActor
@Suite("Cloud guest display helper")
struct CloudGuestDisplayScriptTests {
    @Test("refreshes an already-installed helper before creating a display")
    func refreshesInstalledHelper() {
        let command = CloudGuestDisplayScript.command(action: "create")

        #expect(command.contains("candidate=\"$(mktemp \"$HOME/.cmux/cmux-display.XXXXXX\")\""))
        #expect(command.contains("cmp -s \"$candidate\" \"$path\""))
        #expect(command.contains("pkill -TERM -u \"$(id -u)\" -f \"$path serve\""))
        #expect(command.contains("service_ready=0"))
        #expect(command.contains("for attempt in $(seq 1 100)"))
        #expect(command.contains("[ \"$service_ready\" = 1 ] || exit 1"))
        #expect(command.contains("\"$path\" create"))
    }
}
