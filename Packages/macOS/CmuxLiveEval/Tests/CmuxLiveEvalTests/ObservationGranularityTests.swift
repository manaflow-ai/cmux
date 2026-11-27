import CmuxSwiftRender
import Observation
import Testing
@testable import CmuxLiveEval

/// Proves the core spike question without a GUI: evaluating an interpreted
/// statement inside `withObservationTracking` registers dependencies on
/// exactly the `@Observable` boxes the statement read, and on nothing else.
/// This is the same registration mechanism a SwiftUI body uses.
@MainActor
@Suite struct ObservationGranularityTests {
    let engine: LiveEvalEngine
    let store: LiveStateStore
    let entries: [LiveBlockEntry]

    init() throws {
        engine = LiveEvalEngine(program: LiveProgram.parse(LiveEvalFixtures.source))
        store = engine.makeStore()
        guard case let .stack(_, _, block) = engine.evaluateRoot(LiveScope(store: store)) else {
            throw LiveEvalTestError.unexpectedShape("root is not a stack")
        }
        entries = engine.expandBlock(block)
    }

    private func track(statementAt index: Int) -> ChangeFlag {
        let flag = ChangeFlag()
        withObservationTracking {
            _ = engine.evaluateStatement(entries[index].statement, entries[index].scope)
        } onChange: {
            flag.mark()
        }
        return flag
    }

    @Test func counterTextRegistersOnlyOnCountBox() {
        let flag = track(statementAt: 1) // Text("Count: \(count)")
        store.box("text")?.value = .string("noise")
        store.box("rows")?.value = .array([])
        #expect(flag.fired == false, "mutating unread boxes must not invalidate the counter text")
        store.box("count")?.value = .int(1)
        #expect(flag.fired == true, "mutating the read box must invalidate")
    }

    @Test func echoTextRegistersOnlyOnTextBox() {
        let flag = track(statementAt: 4) // Text("Echo: \(text)")
        store.box("count")?.value = .int(99)
        #expect(flag.fired == false)
        store.box("text")?.value = .string("typed")
        #expect(flag.fired == true)
    }

    @Test func forEachRegistersOnRowsBoxOnly() {
        let flag = track(statementAt: 6) // ForEach($rows, id: \.id)
        store.box("count")?.value = .int(3)
        store.box("text")?.value = .string("x")
        #expect(flag.fired == false)
        store.box("rows")?.value = .array([])
        #expect(flag.fired == true)
    }

    @Test func buttonStatementRegistersOnNothing() {
        let flag = track(statementAt: 0) // Button("Increment") { count += 1 }
        store.box("count")?.value = .int(5)
        store.box("text")?.value = .string("y")
        store.box("rows")?.value = .array([])
        #expect(flag.fired == false, "building a button (title + action thunk) reads no state")
    }

    @Test func bindingGetterRegistersInsideTrackingScope() {
        // A Binding's getter is executed by SwiftUI during the consuming
        // control's update; simulate that consumer with a tracking scope.
        guard case let .textField(_, binding) = engine
            .evaluateStatement(entries[3].statement, entries[3].scope).first
        else {
            Issue.record("statement 3 is not a textField")
            return
        }
        let flag = ChangeFlag()
        withObservationTracking {
            _ = binding.wrappedValue
        } onChange: {
            flag.mark()
        }
        store.box("count")?.value = .int(8)
        #expect(flag.fired == false)
        store.box("text")?.value = .string("via setter path")
        #expect(flag.fired == true)
    }

    @Test func actionMutationFiresRegisteredReaders() {
        guard case let .button(_, increment) = engine
            .evaluateStatement(entries[0].statement, entries[0].scope).first
        else {
            Issue.record("statement 0 is not a button")
            return
        }
        let flag = track(statementAt: 1)
        increment()
        #expect(flag.fired == true, "interpreted Button action mutating the box invalidates readers")
        #expect(store.box("count")?.value == .int(1))
    }
}
