import Testing
@testable import CmuxSwiftRender

/// Behavior of the evaluation node budget: pathological sources must come back
/// as a contained `nil` (so the host's last-good-sticky publish keeps the
/// previous render) while realistic sidebars render unaffected.
@Suite struct EvaluationNodeBudgetTests {
    let interp = SwiftViewInterpreter()

    @Test func pathologicalHugeForEachReturnsNilInsteadOfAHugeTree() {
        // 100_000 rows materialize (the range cap admits exactly 100_000) but
        // must trip the node budget long before the walk finishes.
        let node = interp.evaluate("""
        VStack {
            ForEach(0..<100_000) { i in
                Text("Row \\(i)")
            }
        }
        """)
        #expect(node == nil)
    }

    @Test func pathologicalNestedForEachReturnsNil() {
        // 500 x 500 = 250_000 nodes via nesting; neither loop alone exceeds
        // the range cap, so only the node budget contains this.
        let node = interp.evaluate("""
        VStack {
            ForEach(0..<500) { i in
                HStack {
                    ForEach(0..<500) { j in
                        Text("\\(i).\\(j)")
                    }
                }
            }
        }
        """)
        #expect(node == nil)
    }

    @Test func deepButRealisticListStillRendersCompletely() {
        // An order of magnitude above a typical sidebar, still under budget:
        // every row must be present (no silent truncation of legal sources).
        let node = interp.evaluate("""
        VStack {
            ForEach(0..<400) { i in
                Text("Row \\(i)")
            }
        }
        """)
        #expect(node?.kind == .vstack)
        #expect(node?.children.count == 400)
    }

    @Test func budgetTripIsFastEnoughToBeAContainmentMechanism() {
        // The point of the budget is host responsiveness: tripping must cost
        // milliseconds, not iterate 100k rows doing full work. The bound is
        // deliberately loose (CI machines vary); the failure mode it guards
        // against is multi-second hangs.
        let start = ContinuousClock.now
        _ = interp.evaluate("""
        VStack {
            ForEach(0..<100_000) { i in
                Text("Row \\(i)")
            }
        }
        """)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(5))
    }
}
