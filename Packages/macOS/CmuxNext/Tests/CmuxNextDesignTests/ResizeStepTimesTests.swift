@testable import CmuxNextDesign
import Testing

/// `ResizeStepTimes` measures a phase inside another on one shared value: `ShellWindow.setFrame` measures the step,
/// and the layout root's `layout()`, which runs inside that `setFrame`, measures its screens' fit. As a `mutating`
/// method holding the shared value for the whole body, the inner measure was a second modification inside the first: a
/// Swift exclusivity trap ("Fatal access conflict detected") on the first live resize of a DEV build (other Mac,
/// 9f6ea72a, the first corner drag of resize_hitch).
@MainActor
@Suite(.serialized) struct ResizeStepTimesTests {
    static var shared = ResizeStepTimes()

    @Test func aMeasureInsideAnotherOnTheSameValueRecordsBoth() {
        Self.shared.reset()
        Self.shared.measure("outer") {
            Self.shared.measure("inner") { _ = (0..<100).reduce(0, +) }
        }
        let report = Self.shared.report()
        #expect(report["outer"]?["steps"] as? Int == 1)
        #expect(report["inner"]?["steps"] as? Int == 1)
        #expect((report["outer"]?["max_ms"] as? Double ?? 0) >= (report["inner"]?["max_ms"] as? Double ?? 0),
                "the outer step contains the inner one")
    }
}
