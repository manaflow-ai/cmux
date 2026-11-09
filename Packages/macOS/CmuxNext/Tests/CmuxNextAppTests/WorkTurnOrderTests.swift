import CmuxNextActions
import CmuxNextDaemon
@testable import CmuxNextApp
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

    /// Two Cmd-T presses whose replies come back reversed, the first more than 2 s late (a slow terminal or daemon): the
    /// second's move still waits for the first's, so they settle `a b 1 2 c`, never `a b 2 1 c`.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aLateReplyStillMovesInPressOrder() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let pane = try #require(services.windows.active?.focusedPane)
            let first = try #require(NewTabSlot.reserve(pane.pane, services: services))
            let second = try #require(NewTabSlot.reserve(pane.pane, services: services))
            let ran = Ran()
            let secondWork: ActionWork = Task { @MainActor in _ = await second.earlier?.value; ran.order.append(2); return nil }
            second.fill(secondWork)
            try await Task.sleep(for: .milliseconds(2500))
            let firstWork: ActionWork = Task { @MainActor in _ = await first.earlier?.value; ran.order.append(1); return nil }
            first.fill(firstWork)
            _ = await (firstWork.value, secondWork.value)
            #expect(ran.order == [1, 2])
        }
    }

    /// A new tab whose creation fails drops its reply callback: its move's turn is released at once, so the next new tab's
    /// move does not wait (a timer did hold it 2 s, and before that 10 s).
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aFailedCreationDoesNotDelayTheNextMove() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let pane = try #require(services.windows.active?.focusedPane)
            let surface = try await connection.newTab(in: pane.pane.handle).surface
            try await PasswordManagerRouteTests.until { services.daemon.store.tab(surface: surface) != nil }
            let anchor = try #require(services.daemon.store.tab(surface: surface))
            var failed = NewTabSlot.placing(.after(anchor), services: services, then: nil as (@MainActor (SurfaceID) -> Void)?)
            #expect(failed != nil)
            let next = try #require(NewTabSlot.reserve(pane.pane, services: services))
            failed = nil // the creation failed: its callback is dropped uncalled
            let start = ContinuousClock.now
            let work: ActionWork = Task { @MainActor in _ = await next.earlier?.value; return nil }
            next.fill(work)
            _ = await next.place.value
            #expect(ContinuousClock.now - start < .milliseconds(500), "the next move waited \(ContinuousClock.now - start)")
        }
    }
}
