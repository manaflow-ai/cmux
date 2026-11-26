import Foundation
import Testing
@testable import CmuxControlSocket

/// Regression coverage for the shared numeric param helpers, which must match the
/// legacy `v2Int`/`v2Double` (`as? NSNumber` → `intValue`/`doubleValue`) coercion
/// EXACTLY — including not trapping on out-of-range/NaN doubles (a plain
/// `Int(Double)` traps; the legacy `NSNumber.intValue` clamps).
@MainActor
@Suite("ControlCommandCoordinator numeric params")
struct ControlCommandCoordinatorParamsTests {
    private func coordinator() -> ControlCommandCoordinator {
        ControlCommandCoordinator()
    }

    @Test func intTruncatesTowardZeroLikeNSNumber() {
        let c = coordinator()
        #expect(c.int(["x": .double(2.9)], "x") == 2)
        #expect(c.int(["x": .double(-2.9)], "x") == -2)
        #expect(c.int(["x": .int(7)], "x") == 7)
        #expect(c.int(["x": .string("42")], "x") == 42)
        #expect(c.int(["x": .string("2.5")], "x") == nil)
    }

    @Test func intDoesNotTrapOnOverflowOrNaN() {
        let c = coordinator()
        // Plain Int(1e30)/Int(.nan) would trap; must match NSNumber.intValue.
        #expect(c.int(["x": .double(1e30)], "x") == NSNumber(value: 1e30).intValue)
        #expect(c.int(["x": .double(-1e30)], "x") == NSNumber(value: -1e30).intValue)
        #expect(c.int(["x": .double(.nan)], "x") == NSNumber(value: Double.nan).intValue)
        #expect(c.int(["x": .double(.infinity)], "x") == NSNumber(value: Double.infinity).intValue)
    }

    @Test func intCoercesJSONBooleanLikeLegacy() {
        let c = coordinator()
        #expect(c.int(["x": .bool(true)], "x") == 1)
        #expect(c.int(["x": .bool(false)], "x") == 0)
    }

    @Test func doubleCoercesJSONBooleanLikeLegacy() {
        let c = coordinator()
        #expect(c.double(["x": .bool(true)], "x") == 1.0)
        #expect(c.double(["x": .bool(false)], "x") == 0.0)
        #expect(c.double(["x": .int(3)], "x") == 3.0)
        #expect(c.double(["x": .double(2.5)], "x") == 2.5)
        #expect(c.double(["x": .string("1.25")], "x") == 1.25)
    }

    @Test func numericHelpersReturnNilForAbsentOrNonNumeric() {
        let c = coordinator()
        #expect(c.int([:], "x") == nil)
        #expect(c.int(["x": .null], "x") == nil)
        #expect(c.double(["x": .array([])], "x") == nil)
    }
}
