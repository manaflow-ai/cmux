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
            "CMUX_NEXT_TUI_TERMINAL_HOST_MODEL": "holder",
            "CMUX_NEXT_TUI_HOST_EXE_DIR": "/tmp/hx",
            "PATH": "/usr/bin",
        ])
        #expect(knobs.daemonEnvironment == ["CMUX_TRACE_FLOWS": "/tmp/flows", "CMUX_TUI_TERMINAL_HOST_MODEL": "holder",
                                            "CMUX_TUI_HOST_EXE_DIR": "/tmp/hx"])
    }

    @Test func noKnobsPassNothing() {
        #expect(DaemonDiagnosticKnobs(processEnvironment: ["CMUX_TRACE_FLOWS": "/tmp/x"]).daemonEnvironment.isEmpty)
    }
}
