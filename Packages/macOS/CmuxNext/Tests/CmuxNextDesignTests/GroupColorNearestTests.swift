import CmuxNextDesign
import Testing

/// An imported browser profile keeps its color: the source's RGB maps to the
/// group color nearest by hue, and a gray one stays grey.
@Suite struct GroupColorNearestTests {
    @Test func chromeProfileColorsMapToTheirHue() {
        #expect(GroupColor.nearest(rgb: 0x1A73E8) == .blue)
        #expect(GroupColor.nearest(rgb: 0xD93025) == .red)
        #expect(GroupColor.nearest(rgb: 0x188038) == .green)
        #expect(GroupColor.nearest(rgb: 0xF9AB00) == .yellow)
        #expect(GroupColor.nearest(rgb: 0x9334E6) == .purple)
        #expect(GroupColor.nearest(rgb: 0xE8710A) == .orange)
        #expect(GroupColor.nearest(rgb: 0x12B5CB) == .cyan)
        #expect(GroupColor.nearest(rgb: 0xE52592) == .pink)
    }

    @Test func grayAndBlackStayGrey() {
        #expect(GroupColor.nearest(rgb: 0x808080) == .grey)
        #expect(GroupColor.nearest(rgb: 0x000000) == .grey)
        #expect(GroupColor.nearest(rgb: 0xFFFFFF) == .grey)
    }
}
