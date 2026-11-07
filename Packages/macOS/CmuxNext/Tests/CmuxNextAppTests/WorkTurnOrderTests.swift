import CmuxNextWakeups
import Testing

/// A pane's new tabs move in the order they were asked for, whichever answer comes first (`NewTabSlot`, Ctrl-` then Cmd-T:
/// the page answered before the terminal and moved first, ending before it). `WorkLine` keeps that order.
@MainActor @Suite struct WorkTurnOrderTests {
    @MainActor final class Ran { var order: [Int] = [] }

    @Test func aLaterTurnFilledFirstWaitsForTheEarlierOne() async {
        let line = WorkLine<Int>()
        let first = line.next(limit: .seconds(10), owner: "test.first", passing: -1)
        let second = line.next(limit: .seconds(10), owner: "test.second", passing: -1)
        let ran = Ran()
        second.fill(Task { @MainActor in _ = await second.earlier?.value; ran.order.append(2); return 2 })
        first.fill(Task { @MainActor in _ = await first.earlier?.value; ran.order.append(1); return 1 })
        #expect(await second.place.value == 2)
        #expect(ran.order == [1, 2])
    }

    @Test func aTurnNeverFilledPassesAtItsLimit() async {
        let line = WorkLine<Int>()
        let first = line.next(limit: .milliseconds(20), owner: "test.unfilled", passing: -1)
        let second = line.next(limit: .seconds(10), owner: "test.filled", passing: -1)
        second.fill(Task { @MainActor in _ = await second.earlier?.value; return 2 })
        #expect(await first.place.value == -1)
        #expect(await second.place.value == 2)
    }
}
