#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextWakeups
import Testing

struct NewTerminalTraceTests {
    @Test func provisionalSurfaceCanCorrelateResolvedAttach() {
        let trace = NewTerminalTrace()
        #expect(trace.begin())
        trace.markAction()
        trace.bind(terminal: "terminal-1")
        trace.tabAdded(terminal: "terminal-1", surface: 1 << 62, terminalResourceID: "term_1")

        trace.mark(.attachStart, surface: 42, terminalResourceID: "term_1")
        trace.mark(.attachReplied, surface: 42, terminalResourceID: "term_1")
        trace.mark(.attachEnd, surface: 42, terminalResourceID: "term_1")

        let record = trace.finish(timedOut: false)
        #expect(record?.milliseconds(.attachStart) != nil)
        #expect(record?.milliseconds(.attachReplied) != nil)
        #expect(record?.milliseconds(.attachEnd) != nil)
    }
}
#endif
