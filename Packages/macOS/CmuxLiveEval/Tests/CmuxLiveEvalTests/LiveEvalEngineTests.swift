import CmuxSwiftRender
import SwiftUI
import Testing
@testable import CmuxLiveEval

/// Behavior tests for the engine: structure, binding round-trips, action
/// execution, and shuffle-with-identity. No GUI required.
@MainActor
@Suite struct LiveEvalEngineTests {
    let engine: LiveEvalEngine
    let store: LiveStateStore
    let entries: [LiveBlockEntry]

    init() throws {
        engine = LiveEvalEngine(program: LiveProgram.parse(LiveEvalFixtures.source))
        store = engine.makeStore()
        let root = engine.evaluateRoot(LiveScope(store: store))
        guard case let .stack(axis, spacing, block) = root else {
            throw LiveEvalTestError.unexpectedShape("root is not a stack")
        }
        #expect(axis == .vertical)
        #expect(spacing == 8)
        entries = engine.expandBlock(block)
    }

    /// Re-evaluates the statement at `index` and returns its single node.
    private func node(at index: Int) throws -> LiveNode {
        let nodes = engine.evaluateStatement(entries[index].statement, entries[index].scope)
        guard let first = nodes.first, nodes.count == 1 else {
            throw LiveEvalTestError.unexpectedShape("statement \(index) produced \(nodes.count) nodes")
        }
        return first
    }

    @Test func stateSeedsFromDeclarations() {
        #expect(store.names == ["count", "rows", "text"])
        #expect(store.box("count")?.value == .int(0))
        #expect(store.box("text")?.value == .string(""))
        guard case let .array(rows)? = store.box("rows")?.value else {
            Issue.record("rows is not an array")
            return
        }
        #expect(rows.count == 3)
        #expect(rows[1].member("label") == .string("Beta"))
        #expect(rows[1].member("isOn") == .bool(true))
    }

    @Test func rootEvaluatesOneLevelDeep() throws {
        #expect(entries.count == 9)
        if case .button = try node(at: 0) {} else { Issue.record("0 not button") }
        if case .text = try node(at: 1) {} else { Issue.record("1 not text") }
        if case .divider = try node(at: 2) {} else { Issue.record("2 not divider") }
        if case .textField = try node(at: 3) {} else { Issue.record("3 not textField") }
        if case .text = try node(at: 4) {} else { Issue.record("4 not text") }
        if case .forEach = try node(at: 6) {} else { Issue.record("6 not forEach") }
        if case .spacer = try node(at: 8) {} else { Issue.record("8 not spacer") }
    }

    @Test func counterActionMutatesBoxAndReadingTextSeesIt() throws {
        guard case let .button(title, action) = try node(at: 0) else { return }
        #expect(title == "Increment")
        action()
        action()
        #expect(store.box("count")?.value == .int(2))
        guard case let .text(label) = try node(at: 1) else { return }
        #expect(label == "Count: 2")
    }

    @Test func textFieldBindingRoundTrips() throws {
        guard case let .textField(placeholder, binding) = try node(at: 3) else { return }
        #expect(placeholder == "Type here")
        binding.wrappedValue = "hello"
        #expect(store.box("text")?.value == .string("hello"))
        guard case let .text(echo) = try node(at: 4) else { return }
        #expect(echo == "Echo: hello")
        store.box("text")?.value = .string("external")
        #expect(binding.wrappedValue == "external")
    }

    @Test func forEachRowsCarryIdentityAndProjectedBindings() throws {
        guard case let .forEach(rows) = try node(at: 6) else { return }
        #expect(rows.map(\.id) == ["a", "b", "c"])
        let rowEntries = engine.expandBlock(rows[1].content)
        let nodes = engine.evaluateStatement(rowEntries[0].statement, rowEntries[0].scope)
        guard case let .toggle(title, isOn) = nodes.first else {
            Issue.record("row statement is not a toggle")
            return
        }
        #expect(title == "Beta")
        #expect(isOn.wrappedValue == true)
        isOn.wrappedValue = false
        guard case let .array(updated)? = store.box("rows")?.value else { return }
        #expect(updated[1].member("isOn") == .bool(false))
        #expect(updated[0].member("isOn") == .bool(false))
    }

    @Test func shufflePreservesPerRowToggleStateByIdentity() throws {
        engine.random = SeededGenerator(seed: 7)

        // Flip Gamma (id "c") on through its projected row binding.
        guard case let .forEach(rows) = try node(at: 6) else { return }
        let gammaEntries = engine.expandBlock(rows[2].content)
        guard case let .toggle(_, gammaToggle) = engine
            .evaluateStatement(gammaEntries[0].statement, gammaEntries[0].scope).first
        else { return }
        gammaToggle.wrappedValue = true

        guard case let .button(title, shuffle) = try node(at: 7) else { return }
        #expect(title == "Shuffle")
        shuffle()

        guard case let .forEach(shuffled) = try node(at: 6) else { return }
        #expect(Set(shuffled.map(\.id)) == Set(["a", "b", "c"]))
        #expect(shuffled.map(\.id) != ["a", "b", "c"], "seed 7 must produce a real permutation")

        // The rows moved; per-row toggle state follows the row identity.
        guard let movedGamma = shuffled.first(where: { $0.id == "c" }) else { return }
        let movedEntries = engine.expandBlock(movedGamma.content)
        guard case let .toggle(movedTitle, movedToggle) = engine
            .evaluateStatement(movedEntries[0].statement, movedEntries[0].scope).first
        else { return }
        #expect(movedTitle == "Gamma")
        #expect(movedToggle.wrappedValue == true)

        // A binding captured before the shuffle still targets row "c" by
        // identity, not by its old position.
        #expect(gammaToggle.wrappedValue == true)
        gammaToggle.wrappedValue = false
        #expect(movedToggle.wrappedValue == false)
        guard case let .array(values)? = store.box("rows")?.value else { return }
        let gammaRow = values.first { $0.member("id") == .string("c") }
        #expect(gammaRow?.member("isOn") == .bool(false))
    }
}

enum LiveEvalTestError: Error {
    case unexpectedShape(String)
}
