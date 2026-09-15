import CMUXAgentLaunch
import Testing

@Suite("CLIForwardingLaunchPolicy")
struct CLIForwardingLaunchPolicyTests {
    /// A CLI invocation that reaches the GUI binary with the forwarding
    /// guard already set must not fall through to a GUI launch: hook
    /// commands (`cmux claude-hook …`) would each leave a faceless app
    /// instance running forever.
    @Test("CLI argv with the guard set fails closed")
    func cliArgvWithGuardSetFailsClosed() {
        #expect(
            CLIForwardingLaunchPolicy.decision(
                arguments: ["cmux", "claude-hook", "pre-tool-use"],
                forwardingGuardIsSet: true
            ) == .failForwardingLoop
        )
        #expect(
            CLIForwardingLaunchPolicy.decision(
                arguments: ["cmux", "claude-hook", "pre-tool-use"],
                forwardingGuardIsSet: false
            ) == .forwardToBundledCLI
        )
    }

    /// GUI-style launches (no subcommand, `-psn_...` flags, `cmux://` URLs,
    /// launch sentinels) stay in the app regardless of the forwarding guard.
    @Test("GUI argv launches the app even with the guard set")
    func guiArgvLaunchesAppEvenWithGuardSet() {
        #expect(
            CLIForwardingLaunchPolicy.decision(arguments: ["cmux"], forwardingGuardIsSet: true) == .launchGUI
        )
        #expect(
            CLIForwardingLaunchPolicy.decision(
                arguments: ["cmux", "-psn_0_12345"],
                forwardingGuardIsSet: true
            ) == .launchGUI
        )
        #expect(
            CLIForwardingLaunchPolicy.decision(
                arguments: ["cmux", "cmux://workspace/foo"],
                forwardingGuardIsSet: true
            ) == .launchGUI
        )
        #expect(
            CLIForwardingLaunchPolicy.decision(
                arguments: ["cmux DEV", "DEV"],
                forwardingGuardIsSet: true
            ) == .launchGUI
        )
    }

    /// CLI-style subcommands forward to the bundled CLI on the first pass.
    @Test("CLI subcommands forward to the bundled CLI")
    func cliSubcommandsForward() {
        #expect(CLIForwardingLaunchPolicy.shouldForwardToBundledCLI(arguments: ["cmux", "wait-for", "workspace:1"]))
        #expect(CLIForwardingLaunchPolicy.shouldForwardToBundledCLI(arguments: ["cmux", "hooks", "setup"]))
        #expect(!CLIForwardingLaunchPolicy.shouldForwardToBundledCLI(arguments: ["cmux", "-psn_0_12345"]))
        #expect(!CLIForwardingLaunchPolicy.shouldForwardToBundledCLI(arguments: ["cmux", "cmux://workspace/foo"]))
    }
}
