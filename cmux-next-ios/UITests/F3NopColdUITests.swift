import XCTest

/// Scratch (never lands): an empty *ColdUITests suite beside a profiled UI suite, so the fleet step's
/// `ui_cold` list is not empty (an empty one ends the step under set -u and drops its evidence zip;
/// fixed by #47685).
final class F3NopColdUITests: XCTestCase {
    func testNopCold() {}
}
