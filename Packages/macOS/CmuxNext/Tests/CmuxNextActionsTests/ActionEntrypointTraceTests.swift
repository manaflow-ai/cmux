@testable import CmuxNextActions
import Testing

/// The entrypoint numbers an action signpost's trace ring record carries (p09-observability task 006).
struct ActionEntrypointTraceTests {
    @Test("Every entrypoint has a fixed, distinct ring position below 255")
    func tracePositionsAreFixedAndDistinct() {
        let positions = ActionEntrypoint.allCases.map(\.tracePosition)
        #expect(positions == [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(Set(positions).count == ActionEntrypoint.allCases.count)
    }
}
