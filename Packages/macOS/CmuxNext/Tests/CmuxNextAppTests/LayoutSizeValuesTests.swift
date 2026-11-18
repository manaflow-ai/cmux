import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import Testing

/// `LayoutIntent.sizes` and `LayoutHandleMap.sizeValues`: the size values an intent asks for, then those values in the
/// daemon's form, in their order, or nil when one of them cannot go to the daemon now. The app then sends none of
/// them: a change of several values is all or nothing.
@MainActor
struct LayoutSizeValuesTests {
    private func handles() -> LayoutHandleMap {
        var handles = LayoutHandleMap()
        // `new` is a stand-in: its handle is in the range no daemon pane has (`ProvisionalPane`, from 1 << 62).
        handles.panes = ["p0": DaemonPaneID(rawValue: 2), "p1": DaemonPaneID(rawValue: 5), "new": DaemonPaneID(rawValue: (1 << 62) + 7)]
        handles.splits = ["x": DaemonSplitID(rawValue: 4)]
        return handles
    }

    @Test func theValuesKeepTheirOrderAndTakeTheDaemonsHandles() {
        let values: [LayoutIntent.SizeValue] = [.width("c0", anyPane: "p0", 0.25), .ratio("x", 0.5), .width("c1", anyPane: "p1", 0.75)]
        let want: [SetLayoutSizesRequest.Value] = [
            .width(pane: DaemonPaneID(rawValue: 2), 0.25), .ratio(DaemonSplitID(rawValue: 4), 0.5), .width(pane: DaemonPaneID(rawValue: 5), 0.75),
        ]
        #expect(handles().sizeValues(values) == want)
    }

    @Test func eachSizeIntentGivesItsValuesAndTransaction() {
        let transaction = LayoutTransactionID.make()
        let ratio = LayoutIntent.setSplitRatio("x", ratio: 0.5, transaction: transaction, phase: .ended)
        #expect(ratio.sizes?.values == [.ratio("x", 0.5)])
        #expect(ratio.sizes?.transaction == transaction)
        let width = LayoutIntent.setColumnWidth("c0", anyPane: "p0", width: 0.25, transaction: transaction, phase: .ended)
        #expect(width.sizes?.values == [.width("c0", anyPane: "p0", 0.25)])
        #expect(width.sizes?.transaction == transaction)
        let both: [LayoutIntent.SizeValue] = [.width("c0", anyPane: "p0", 0.25), .ratio("x", 0.5)]
        #expect(LayoutIntent.setLayoutSizes(both, transaction: transaction).sizes?.values == both)
        #expect(LayoutIntent.focus("p0").sizes?.values == nil)
        #expect(LayoutIntent.cancelGesture(transaction).sizes?.values == nil)
    }

    @Test func aValueThatCannotGoRefusesEveryValue() {
        let good = LayoutIntent.SizeValue.width("c0", anyPane: "p0", 0.25)
        #expect(handles().sizeValues([good, .ratio("gone", 0.5)]) == nil, "a split with no handle went")
        #expect(handles().sizeValues([good, .width("c1", anyPane: "gone", 0.75)]) == nil, "a pane with no handle went")
        #expect(handles().sizeValues([good, .width("c2", anyPane: "new", 0.75)]) == nil, "a pane the daemon has not made went")
        #expect(handles().sizeValues([good]) != nil)
    }
}
