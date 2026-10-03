import Testing
@testable import CmuxCloud

@Suite("Cloud guest display helper")
struct CloudGuestDisplayScriptTests {
    @Test("refreshes an already-installed helper before creating a display")
    func refreshesInstalledHelper() {
        let command = CloudGuestDisplayScript.command(action: "create")

        #expect(command.contains("candidate=\"$(mktemp \"$HOME/.cmux/cmux-display.XXXXXX\")\""))
        #expect(command.contains("cmp -s \"$candidate\" \"$path\""))
        #expect(command.contains("pkill -TERM -u \"$(id -u)\" -f \"$path serve\""))
        #expect(command.contains("\"$path\" create"))
    }
}
