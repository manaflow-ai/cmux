import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// The main task board names the running task's owner in the crash-key page: the owner's
/// stable key while its work runs, the covered task's owner back after a span, 0 between tasks.
struct MainTaskBoardCrashKeysTests {
    @Test func aSpanNamesItsOwnerAndPutsTheCoveredOwnerBack() {
        let board = MainTaskBoard()
        let page = CrashKeyPage(identity: .init(role: .app))
        #expect(board.attachCrashKeys(page))
        #expect(!board.attachCrashKeys(CrashKeyPage(identity: .init(role: .app))), "a second page replaced the first")
        let outer = board.internOwner("test.outer"), inner = board.internOwner("test.inner")
        let outerToken = board.beginSpan(.input, owner: outer, budgetNanos: 0, startNanos: 1)
        #expect(page.value(.mainTaskOwner) == CrashKeySlots.stableKey("test.outer"))
        let innerToken = board.beginSpan(.input, owner: inner, budgetNanos: 0, startNanos: 2)
        #expect(page.value(.mainTaskOwner) == CrashKeySlots.stableKey("test.inner"))
        board.endSpan(innerToken, nowNanos: 3)
        #expect(page.value(.mainTaskOwner) == CrashKeySlots.stableKey("test.outer"), "the covered owner did not come back")
        board.endSpan(outerToken, nowNanos: 4)
        #expect(page.value(.mainTaskOwner) == 0, "the owner stayed after its work")
    }

    @Test func aBoardWithNoPageNamesNothing() {
        let board = MainTaskBoard()
        let page = CrashKeyPage(identity: .init(role: .app))
        let token = board.beginSpan(.input, owner: board.internOwner("test.unnamed"), budgetNanos: 0, startNanos: 1)
        board.endSpan(token, nowNanos: 2)
        #expect(page.value(.mainTaskOwner) == 0)
    }
}
