import Testing
@testable import CmuxNextDaemon

struct DaemonDiagnosticKnobsTests {
    /// The app's CMUX_NEXT_ knobs reach the daemon under its names; a stripped daemon name or an empty
    /// value passes nothing (trace.py's flows and spans were empty because the strip removed them).
    @Test func theAppsKnobsReachTheDaemonUnderItsNames() {
        let knobs = DaemonDiagnosticKnobs(processEnvironment: [
            "CMUX_NEXT_TRACE_FLOWS": "/tmp/flows",
            "CMUX_NEXT_TUI_DEBUG_SPANS": "",
            "CMUX_TUI_DEBUG_SPANS": "/tmp/stale",
            "PATH": "/usr/bin",
        ])
        #expect(knobs.daemonEnvironment == ["CMUX_TRACE_FLOWS": "/tmp/flows"])
    }

    /// holder-dogfood's holder model: the daemon's own name is stripped from the app's launch, so the
    /// model ran as `hosts` on every fleet run ("no holder process"); the app's knob passes it on.
    @Test func theTerminalHostModelReachesTheDaemon() {
        let knobs = DaemonDiagnosticKnobs(processEnvironment: ["CMUX_NEXT_TUI_TERMINAL_HOST_MODEL": "holder"])
        #expect(knobs.daemonEnvironment == ["CMUX_TUI_TERMINAL_HOST_MODEL": "holder"])
    }

    /// R-DAEMON-STATE stage S1 (handoff/rewrites/R-DAEMON-STATE/DESIGN.md): the input lane's switch must reach the
    /// daemon the app launches, or a typing A/B on the real app measures the old path in both arms (the app strips
    /// the daemon's own `CMUX_TUI_RDS_INPUT` from its launch).
    @Test func theInputLaneSwitchReachesTheDaemon() {
        let knobs = DaemonDiagnosticKnobs(processEnvironment: ["CMUX_NEXT_TUI_RDS_INPUT": "1"])
        #expect(knobs.daemonEnvironment == ["CMUX_TUI_RDS_INPUT": "1"])
    }

    /// R-LIFECYCLE ORPHANS: the keepers rule is on by default; a dogfood report of an owner that stopped too soon
    /// turns it off on the app's launch, and the app strips the daemon's own `CMUX_TUI_OWNER_KEEPERS`.
    @Test func theOwnerKeepersSwitchReachesTheDaemon() {
        let knobs = DaemonDiagnosticKnobs(processEnvironment: ["CMUX_NEXT_TUI_OWNER_KEEPERS": "0"])
        #expect(knobs.daemonEnvironment == ["CMUX_TUI_OWNER_KEEPERS": "0"])
    }

    /// The Chief owner (`cmux-chief-*`) follows the same keepers rule, so the off switch must reach its `ensure` too;
    /// the Chief launch keeps only a short list of variables (`DaemonLauncher.chiefEnvironment`).
    @Test func theOwnerKeepersSwitchReachesTheChiefOwner() {
        let environment = DaemonLauncher.chiefEnvironment(["HOME": "/h", "CMUX_NEXT_TUI_OWNER_KEEPERS": "0",
                                                           "CMUX_NEXT_TRACE_FLOWS": "/tmp/x"])
        #expect(environment == ["HOME": "/h", "CMUX_TUI_OWNER_KEEPERS": "0"])
    }

    @Test func noKnobsPassNothing() {
        #expect(DaemonDiagnosticKnobs(processEnvironment: ["CMUX_TRACE_FLOWS": "/tmp/x"]).daemonEnvironment.isEmpty)
    }
}
