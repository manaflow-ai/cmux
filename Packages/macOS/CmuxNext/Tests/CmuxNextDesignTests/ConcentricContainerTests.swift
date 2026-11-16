import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// The container side of the concentric rule (Lawrence 2026-11-15: "all dialogs needs concentric padding with
/// buttons inside"): pure math, fixed numbers.
@Suite struct ConcentricContainerTests {
    @Test func theContainerRoundsFromItsControls() {
        let toast = ConcentricContainer(childRadius: 8, padding: 8)
        #expect(toast.outerRadius == 16)
        #expect(toast.textInset == 16)
        #expect(ConcentricContainer(outerRadius: 16, padding: 6).childRadius == 10)
        #expect(ConcentricContainer(outerRadius: 4, padding: 6).childRadius == 0, "never a negative corner")
    }

    @Test func aCapsuleHoldsCapsules() {
        let pill = ConcentricContainer.capsule(controlHeight: 22, padding: 8)
        #expect(pill.childRadius == 11)
        #expect(pill.outerRadius == 19)
        #expect(pill.outerRadius(fitting: CGSize(width: 300, height: 38)) == 19)
        #expect(pill.childRadius(fitting: CGSize(width: 20, height: 20)) == 10)
    }

    @Test func aControlInTheCornerMustShareItsCenter() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 38)
        let close = CGRect(x: 270, y: 8, width: 22, height: 22)
        #expect(ConcentricContainer.violations(child: close, childRadius: 8, in: bounds, outerRadius: 16, padding: 8).isEmpty)
        let pinched = ConcentricContainer.violations(child: close, childRadius: 8, in: bounds, outerRadius: 8, padding: 8)
        #expect(pinched.contains { $0.hasPrefix("child radius 8") }, "\(pinched)")
    }

    @Test func nearEdgesMustAllBeThePadding() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 38)
        let close = CGRect(x: 272, y: 9, width: 20, height: 20)
        let broken = ConcentricContainer.violations(child: close, childRadius: 8, in: bounds, outerRadius: 16, padding: 8)
        #expect(broken.contains("top inset 9 is not the padding 8"), "\(broken)")
        #expect(broken.contains("bottom inset 9 is not the padding 8"), "\(broken)")
    }

    @Test func aControlFarFromTheEdgesIsFree() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let middle = CGRect(x: 150, y: 130, width: 100, height: 26)
        #expect(ConcentricContainer.violations(child: middle, childRadius: 3, in: bounds, outerRadius: 24, padding: 16).isEmpty)
    }
}
