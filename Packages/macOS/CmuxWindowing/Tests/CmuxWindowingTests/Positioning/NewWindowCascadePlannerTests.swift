import CoreGraphics
import Testing

@testable import CmuxWindowing

@Suite("NewWindowCascadePlanner")
struct NewWindowCascadePlannerTests {
    @Test("centers when the source screen is unresolvable")
    func centersWithoutScreen() {
        let planner = NewWindowCascadePlanner()
        let placement = planner.placement(
            sourceFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
            hasResolvableScreen: false,
            windowSize: CGSize(width: 800, height: 600)
        )
        #expect(placement == .center)
    }

    @Test("cascades down-right from the source frame's top-left, preserving size")
    func cascadesFromSourceTopLeft() {
        let planner = NewWindowCascadePlanner(cascadeOffset: 24)
        let source = CGRect(x: 100, y: 200, width: 800, height: 600)
        let windowSize = CGSize(width: 640, height: 480)
        let placement = planner.placement(
            sourceFrame: source,
            hasResolvableScreen: true,
            windowSize: windowSize
        )
        // Matches the legacy positionNewMainWindow math:
        // x = source.minX + offset; y = source.maxY - offset - height.
        let expected = CGRect(
            x: 100 + 24,
            y: (200 + 600) - 24 - 480,
            width: 640,
            height: 480
        )
        #expect(placement == .frame(expected))
    }

    @Test("honors a custom cascade offset")
    func honorsCustomOffset() {
        let planner = NewWindowCascadePlanner(cascadeOffset: 40)
        let source = CGRect(x: 0, y: 0, width: 500, height: 500)
        let placement = planner.placement(
            sourceFrame: source,
            hasResolvableScreen: true,
            windowSize: CGSize(width: 300, height: 300)
        )
        #expect(placement == .frame(CGRect(x: 40, y: 500 - 40 - 300, width: 300, height: 300)))
    }

    @Test("default floor matches the legacy 460x360 minimum")
    func defaultMinimumSize() {
        let planner = NewWindowCascadePlanner()
        #expect(planner.minimumWindowSize == CGSize(width: 460, height: 360))
        #expect(planner.cascadeOffset == 24)
    }
}
