import XCTest

extension XCUIElement {
    /// Waits until the element can take a tap. The terminal's key row opens only with the soft
    /// keyboard (Leo, 2026-11-23: "why are those things always showing?"), so its keys exist
    /// before their slot has finished opening (0.25 s) or a scroller has stopped moving.
    @MainActor
    @discardableResult
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return element.exists && element.isHittable
        }, object: self)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }
}
