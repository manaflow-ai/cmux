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

    /// The columns whose ended widths `intent` carries, in its order.
    static func columns(_ intent: LayoutIntent) -> [ColumnID] {
        switch intent {
        case let .setColumnWidth(column, _, _, _, .ended):
            return [column]
        case let .setLayoutSizes(values, _):
            return values.compactMap { value -> ColumnID? in
                guard case let .width(column, _, _) = value else { return nil }
                return column
            }
        default:
            return []
        }
    }

    @Test func aChangeSentFromInsideAnotherKeepsTheOuterRefusal() {
        let model = Self.model()
        let outer = EndedValues([.width("c0", 0.55), .width("c1", 0.45)]), inner = EndedValues([.width("c2", 0.6)])
        var sent: [[ColumnID]] = []
        model.intentHandler = { intent in
            sent.append(Self.columns(intent))
            // The outer change: another change goes out in its turn, then the app refuses the outer one.
            if case let .setLayoutSizes(_, transaction) = intent {
                #expect(inner.send(in: model))
                model.rejectTransaction(transaction)
            }
        }
        #expect(!outer.send(in: model), "the outer change said it went after the app refused it")
        #expect(sent == [["c0", "c1"], ["c2"]], "the two changes went to the app as \(sent)")
        #expect(Self.widths(model) == [0.5, 0.5, 0.6])
    }

    @Test func aRefusedChangeSaysItDidNotGoAndShowsNothing() {
        let model = Self.model()
        model.intentHandler = { intent in
            if case let .setLayoutSizes(_, transaction) = intent { model.rejectTransaction(transaction) }
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

    /// A change of more than one value goes to the app as one intent, so the app can send it as one daemon command
    /// (`set-layout-sizes`: one commit, every value or none). One intent for each value is one daemon commit for each: a
    /// value the daemon refuses after it applied another leaves that other one applied.
    @Test func aChangeOfTwoValuesGoesToTheAppAsOneIntent() {
        let model = Self.model()
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        #expect(EndedValues([.width("c0", 0.55), .width("c1", 0.45)]).send(in: model))
        #expect(intents.count == 1, "a change of two values went to the app as \(intents.count) intents")
        #expect(Self.widths(model) == [0.55, 0.45, 0.5])
    }

    /// The one intent carries every value the model shows, in the change's order, under the change's transaction.
    @Test func theOneIntentCarriesTheShownValuesInOrder() {
        let model = Self.model()
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        let change = EndedValues([.width("c1", 0.45), .width("c0", 0.55)])
        #expect(change.send(in: model))
        let want = LayoutIntent.setLayoutSizes([.width("c1", anyPane: "p1", 0.45), .width("c0", anyPane: "p0", 0.55)],
                                               transaction: change.transaction)
        #expect(intents == [want], "the change went to the app as \(intents)")
    }

    /// One value has nothing to make atomic: it goes as its own command, as before.
    @Test func aChangeOfOneValueGoesAsItsOwnCommand() {
        let model = Self.model()
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        let change = EndedValues([.width("c0", 0.55)])
        #expect(change.send(in: model))
        let want = LayoutIntent.setColumnWidth("c0", anyPane: "p0", width: 0.55, transaction: change.transaction, phase: .ended)
        #expect(intents == [want], "the change went to the app as \(intents)")
    }

    /// The one intent has one reply. A daemon snapshot from before it does not take the change back; the snapshot after
    /// it shows the daemon's values, with nothing held over them.
    @Test func oneReplySettlesAChangeOfTwoValues() {
        let model = Self.model()
        model.intentHandler = { _ in }
        func daemon(_ c0: Double, _ c1: Double) -> [LayoutScreen] {
            let columns = [LayoutColumn(id: "c0", width: c0, root: .leaf("p0")), LayoutColumn(id: "c1", width: c1, root: .leaf("p1")),
                           LayoutColumn(id: "c2", width: 0.5, root: .leaf("p2"))]
            return [LayoutScreen(id: "s", name: "s", layout: .columns(columns))]
        }
        let change = EndedValues([.width("c0", 0.55), .width("c1", 0.45)])
        #expect(change.send(in: model))
        model.apply(screens: daemon(0.5, 0.5))
        #expect(Self.widths(model) == [0.55, 0.45, 0.5], "a snapshot before the reply took the change back")
        model.settleTransaction(change.transaction)
        model.apply(screens: daemon(0.6, 0.4))
        #expect(Self.widths(model) == [0.6, 0.4, 0.5], "the change's one reply did not settle both of its widths")
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
        var sent: [[ColumnID]] = []
        model.intentHandler = { intent in
            sent.append(Self.columns(intent))
            if case let .setLayoutSizes(_, transaction) = intent {
                _ = inner.send(in: model)
                model.rejectTransaction(transaction)
            }
        }
        #expect(!outer.send(in: model), "the outer change said it went after the app refused its transaction")
        #expect(sent == [["c0", "c1"], ["c2"]], "the two changes went to the app as \(sent)")
        #expect(Self.widths(model) == [0.5, 0.5, 0.5], "the refused transaction still shows \(Self.widths(model))")
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
