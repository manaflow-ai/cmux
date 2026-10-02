@testable import CmuxNextIcons
import Testing

struct IconMetricsTests {
    @Test func rowSizeIsAFifthLargerThanTheLabelAndNeverBelowTheFloor() {
        #expect(IconMetrics.rowSize(forLabelPointSize: 13) == 16)
        #expect(IconMetrics.rowSize(forLabelPointSize: 11) == 13)
        #expect(IconMetrics.rowSize(forLabelPointSize: 8) == 12)
        #expect(IconMetrics.floor == 12)
    }
}
