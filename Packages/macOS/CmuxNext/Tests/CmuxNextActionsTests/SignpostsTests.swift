import CoreFoundation
import CmuxNextSignposts
import Testing

@Suite("Signposts", .serialized)
@MainActor
struct SignpostsTests {
    /// Runs one main run-loop turn. A mode with no source returns before notifying observers, so
    /// a far-future timer keeps the default mode non-empty for the turn.
    private func turn() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        CFRunLoopTimerInvalidate(timer)
    }

    @Test("CommitBoundary runs its work once, when the main run-loop turn ends")
    func commitBoundaryRunsOnceAfterTheTurn() {
        var runs = 0
        CommitBoundary().after { runs += 1 }
        #expect(runs == 0)
        turn()
        #expect(runs == 1)
        turn()
        #expect(runs == 1)
    }

    @Test("Boundaries asked for in one turn all run at its end, in order")
    func boundariesInOneTurnRunInOrder() {
        var order: [Int] = []
        CommitBoundary().after { order.append(1) }
        CommitBoundary().after { order.append(2) }
        turn()
        #expect(order.sorted() == [1, 2])
    }

    @Test("An interval runs its body and returns its value")
    func intervalReturnsTheBodyValue() throws {
        let value = Signposter.action.interval(.actionPerform, "id=test") { 42 }
        #expect(value == 42)
        struct Failure: Error {}
        #expect(throws: Failure.self) {
            try Signposter.action.interval(.actionPerform) { throw Failure() }
        }
    }

    @Test("Every catalog name is <category>.<what> of the category that emits it", arguments: [
        SignpostName.actionPerform, .actionCommit, .motionFrame, .motionRun, .keyToFrame, .switchWorkspace,
        .switchTab, .switchPaneFocus, .createTab, .createWorkspace, .cefPump, .cefCreateBrowser,
    ])
    func namesCarryTheirCategory(_ name: SignpostName) {
        #expect(name.description.hasPrefix(name.category.rawValue + "."))
        #expect(name.description.count > name.category.rawValue.count + 1)
    }
}
