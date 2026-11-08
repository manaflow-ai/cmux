import CmuxNextBridge
@testable import CmuxNextLayout
import Testing

/// `EndedValues` (FRAME OWNER REFACTOR KEYS, reviews of #34123): a key press's or a drag release's values go out as one
/// change, all or nothing, and `send` says whether they went. Codex review 4 (FIX at bf4dfe9891a7): the refusal of the
/// change being sent lived in one slot, so a second change sent from inside the first one's intent handler took it over,
/// and a refusal of the first after that was lost: the first sent its other values and said they went.
@MainActor
struct EndedValuesTests {
    static func model() -> LayoutModel {
        let columns = [LayoutColumn(id: "c0", width: 0.5, root: .leaf("p0")), LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
                       LayoutColumn(id: "c2", width: 0.5, root: .leaf("p2"))]
        return LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p0")
    }

    static func widths(_ model: LayoutModel) -> [Double] { model.screens[0].layout.columns.map(\.width) }

    @Test func aChangeSentFromInsideAnotherKeepsTheOuterRefusal() {
        let model = Self.model()
        let outer = EndedValues([.width("c0", 0.55), .width("c1", 0.45)]), inner = EndedValues([.width("c2", 0.6)])
        var sent: [ColumnID] = []
        model.intentHandler = { intent in
            guard case let .setColumnWidth(column, _, _, transaction, .ended) = intent else { return }
            sent.append(column)
            // The outer change's first value: another change goes out in its turn, then the app refuses the outer one.
            if column == "c0" {
                #expect(inner.send(in: model))
                model.rejectTransaction(transaction)
            }
        }
        #expect(!outer.send(in: model), "the outer change said it went after the app refused it")
        #expect(sent == ["c0", "c2"], "the refused outer change still sent \(sent)")
        #expect(Self.widths(model) == [0.5, 0.5, 0.6])
    }

    @Test func aRefusalOfTheLastValueSaysTheChangeDidNotGo() {
        let model = Self.model()
        model.intentHandler = { intent in
            if case .setColumnWidth("c1", _, _, let transaction, .ended) = intent { model.rejectTransaction(transaction) }
        }
        #expect(!EndedValues([.width("c0", 0.55), .width("c1", 0.45)]).send(in: model))
        #expect(Self.widths(model) == [0.5, 0.5, 0.5], "a refused change still shows \(Self.widths(model))")
    }

    @Test func aRefusalOfAnotherChangeLeavesThisOneSent() {
        let model = Self.model()
        let other = LayoutTransactionID.make()
        model.intentHandler = { _ in model.rejectTransaction(other) }
        #expect(EndedValues([.width("c0", 0.55), .width("c1", 0.45)]).send(in: model))
        #expect(Self.widths(model) == [0.55, 0.45, 0.5])
    }

    @Test func withNoAppTheChangeShowsAndCountsAsSent() {
        let model = Self.model()
        #expect(EndedValues([.width("c0", 0.55), .width("c1", 0.45)]).send(in: model))
        #expect(Self.widths(model) == [0.55, 0.45, 0.5])
    }

    /// Codex review 4: the daemon numbers remembered the newest transaction only, so a change sent between two values of
    /// another gave the other's second value a new number: two undo steps for one press.
    @Test func aTransactionKeepsItsNumberWhenAnotherGoesOutBetweenItsValues() throws {
        var numbers = GestureTransactionNumbers()
        let a = LayoutTransactionID.make(), b = LayoutTransactionID.make()
        let first = numbers.number(for: a)
        _ = numbers.number(for: b)
        #expect(numbers.number(for: a) == first, "the second value of a took a new number after b went out")
    }

    /// Codex review 5 (FIX at d307c16972b5): the refusal state was one entry per transaction, so a change sent from inside
    /// another of the same transaction ended that entry, and a refusal after it was lost.
    @Test func aChangeSentInsideOneOfItsOwnTransactionKeepsTheRefusal() {
        let model = Self.model()
        let transaction = LayoutTransactionID.make()
        let outer = EndedValues([.width("c0", 0.55), .width("c1", 0.45)], transaction: transaction)
        let inner = EndedValues([.width("c2", 0.6)], transaction: transaction)
        var sent: [ColumnID] = [], nested = false
        model.intentHandler = { intent in
            guard case let .setColumnWidth(column, _, _, transaction, .ended) = intent else { return }
            sent.append(column)
            if column == "c0", !nested {
                nested = true
                _ = inner.send(in: model)
                model.rejectTransaction(transaction)
            }
        }
        #expect(!outer.send(in: model), "the outer change said it went after the app refused its transaction")
        #expect(!sent.contains("c1"), "the refused outer change still sent c1: \(sent)")
    }

    /// Codex review 5: the daemon numbers kept only the last 32 transactions, so 32 others numbered between two values of
    /// one transaction gave its second value a new number (two undo steps for one change).
    @Test func aTransactionKeepsItsNumberWhileManyOthersGoOut() {
        var numbers = GestureTransactionNumbers()
        let a = LayoutTransactionID.make()
        let first = numbers.number(for: a)
        for _ in 0..<40 { _ = numbers.number(for: .make()) }
        #expect(numbers.number(for: a) == first, "a's second value took a new number after 40 other transactions")
    }

    /// A transaction whose commands were all answered is done: a value after it is a step of its own.
    @Test func aTransactionAnsweredInFullTakesANewNumber() {
        var numbers = GestureTransactionNumbers()
        let a = LayoutTransactionID.make()
        let first = numbers.number(for: a)
        #expect(numbers.number(for: a) == first)
        numbers.answered(a)
        #expect(numbers.number(for: a) == first, "a still had a command in flight")
        numbers.answered(a)
        numbers.answered(a)
        #expect(numbers.number(for: a) != first)
    }
}
