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

    @Test func noKnobsPassNothing() {
        #expect(DaemonDiagnosticKnobs(processEnvironment: ["CMUX_TRACE_FLOWS": "/tmp/x"]).daemonEnvironment.isEmpty)
    }
}
