import CmuxSwiftRender
import Testing
@testable import CmuxLiveEval

/// Measures interpreted body re-evaluation cost. The spike pass criterion is
/// per-keystroke re-eval under ~2ms at realistic sidebar size. Two numbers
/// matter: the steady-state cost (only the stubs that read `text` re-run,
/// thanks to per-box granularity) and the worst-case full-tree walk (what a
/// coarse epoch-counter fallback would pay on every change).
@MainActor
@Suite struct ReEvalBenchmarkTests {
    /// Recursively evaluates every statement of every nested block, the way
    /// SwiftUI would if every stub were invalidated at once.
    private func evaluateFullTree(_ engine: LiveEvalEngine, _ store: LiveStateStore) -> Int {
        var nodeCount = 0
        var pending: [LiveBlock] = []
        let root = engine.evaluateRoot(LiveScope(store: store))
        collect(root, into: &pending, counting: &nodeCount)
        while let block = pending.popLast() {
            for entry in engine.expandBlock(block) {
                for node in engine.evaluateStatement(entry.statement, entry.scope) {
                    collect(node, into: &pending, counting: &nodeCount)
                }
            }
        }
        return nodeCount
    }

    private func collect(_ node: LiveNode, into pending: inout [LiveBlock], counting count: inout Int) {
        count += 1
        switch node {
        case let .stack(_, _, content):
            pending.append(content)
        case let .forEach(rows):
            pending.append(contentsOf: rows.map(\.content))
        default:
            break
        }
    }

    @Test func perKeystrokeSteadyStateCost() throws {
        let engine = LiveEvalEngine(program: LiveProgram.parse(LiveEvalFixtures.source))
        let store = engine.makeStore()
        guard case let .stack(_, _, block) = engine.evaluateRoot(LiveScope(store: store)) else {
            throw LiveEvalTestError.unexpectedShape("root is not a stack")
        }
        let entries = engine.expandBlock(block)
        let textField = entries[3]
        let echo = entries[4]
        let clock = ContinuousClock()
        let iterations = 2000
        // Warm up syntax-tree caches.
        for _ in 0..<50 {
            _ = engine.evaluateStatement(echo.statement, echo.scope)
        }
        let elapsed = clock.measure {
            for index in 0..<iterations {
                store.box("text")?.value = .string("typing pass \(index)")
                _ = engine.evaluateStatement(textField.statement, textField.scope)
                _ = engine.evaluateStatement(echo.statement, echo.scope)
            }
        }
        let perKeystroke = elapsed / iterations
        print("[bench] steady-state per-keystroke re-eval (TextField + echo stubs): \(perKeystroke)")
        #expect(perKeystroke < .milliseconds(2))
    }

    @Test func fullTreeReEvalAtSidebarSize() throws {
        let source = LiveEvalFixtures.sidebarSizedSource(sections: 6, rowsPerSection: 10)
        let engine = LiveEvalEngine(program: LiveProgram.parse(source))
        let store = engine.makeStore()
        let nodeCount = evaluateFullTree(engine, store)
        print("[bench] sidebar-sized tree nodes per full walk: \(nodeCount)")
        #expect(nodeCount > 150, "fixture should be realistically sized, got \(nodeCount)")

        let clock = ContinuousClock()
        let iterations = 200
        for _ in 0..<10 {
            _ = evaluateFullTree(engine, store)
        }
        let elapsed = clock.measure {
            for index in 0..<iterations {
                store.box("query")?.value = .string("search \(index)")
                _ = evaluateFullTree(engine, store)
            }
        }
        let perPass = elapsed / iterations
        print("[bench] worst-case full-tree re-eval per keystroke: \(perPass)")
        // The 2ms pass criterion applies to what SwiftUI actually re-runs per
        // keystroke (the steady-state test above): per-box invalidation means
        // a full-tree walk only happens on first render or an epoch-fallback.
        // This loose bound guards against pathological regression; the
        // measured value is reported for the writeup (debug vs release).
        #expect(perPass < .milliseconds(50))
    }
}
