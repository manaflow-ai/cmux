import CoreGraphics
@testable import CmuxNextIcons
import Testing

struct IconMetricsTests {
    @Test func rowSizeIsAFifthLargerThanTheLabelAndNeverBelowTheFloor() {
        #expect(CGFloat.iconRowSize(forLabelPointSize: 13) == 16)
        #expect(CGFloat.iconRowSize(forLabelPointSize: 11) == 13)
        #expect(CGFloat.iconRowSize(forLabelPointSize: 8) == 12)
        #expect(CGFloat.iconFloor == 12)
    }
}
