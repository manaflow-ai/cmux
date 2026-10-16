import Foundation
import Testing
@testable import CmuxBrowser

struct BrowserHiddenWebViewMemoryBudgetPlannerTests {
    private typealias Pane = BrowserHiddenWebViewMemoryBudgetPlanner.Pane
    private static let megabyte: UInt64 = 1024 * 1024
    private let now = Date()

    @Test("Hidden panes under the budget are all kept")
    func keepsHiddenPanesUnderBudget() {
        let panes = [hidden(processID: 1, minutesAgo: 30), hidden(processID: 2, minutesAgo: 20)]

        let plan = BrowserHiddenWebViewMemoryBudgetPlanner(budgetMB: 1024)
            .plan(panes: panes) { _ in 400 * Self.megabyte }

        #expect(plan.hiddenFootprintBytes == 800 * Self.megabyte)
        #expect(plan.panesToDiscard.isEmpty)
    }

    @Test("Over the budget, the pane hidden longest goes first until hidden memory fits")
    func discardsOldestHiddenFirstUntilUnderBudget() {
        let newest = hidden(processID: 1, minutesAgo: 10)
        let oldest = hidden(processID: 2, minutesAgo: 40)
        let middle = hidden(processID: 3, minutesAgo: 25)

        let plan = BrowserHiddenWebViewMemoryBudgetPlanner(budgetMB: 1024)
            .plan(panes: [newest, oldest, middle]) { _ in 600 * Self.megabyte }

        #expect(plan.panesToDiscard == [oldest.id, middle.id])
        #expect(plan.remainingHiddenFootprintBytes == 600 * Self.megabyte)
    }

    @Test("A process that also backs a visible pane is neither counted nor discarded")
    func ignoresProcessSharedWithVisiblePane() {
        let visible = Pane(id: UUID(), processID: 1, isVisible: true, hiddenAt: nil, isEvictable: false)
        let sharedHidden = hidden(processID: 1, minutesAgo: 60)
        let ownHidden = hidden(processID: 2, minutesAgo: 5)
        var measured: [Int] = []

        let plan = BrowserHiddenWebViewMemoryBudgetPlanner(budgetMB: 256)
            .plan(panes: [visible, sharedHidden, ownHidden]) { processID in
                measured.append(processID)
                return 600 * Self.megabyte
            }

        #expect(measured == [2])
        #expect(plan.hiddenFootprintBytes == 600 * Self.megabyte)
        #expect(plan.panesToDiscard == [ownHidden.id])
    }

    @Test("Hidden panes that share a process are discarded together, dated by the newest")
    func discardsSharedHiddenProcessAsUnit() {
        let sharedOld = hidden(processID: 1, minutesAgo: 60)
        let sharedRecent = hidden(processID: 1, minutesAgo: 5)
        let alone = hidden(processID: 2, minutesAgo: 30)

        let plan = BrowserHiddenWebViewMemoryBudgetPlanner(budgetMB: 700)
            .plan(panes: [sharedOld, sharedRecent, alone]) { _ in 400 * Self.megabyte }

        #expect(plan.panesToDiscard == [alone.id])

        let tighter = BrowserHiddenWebViewMemoryBudgetPlanner(budgetMB: 256)
            .plan(panes: [sharedOld, sharedRecent, alone]) { _ in 400 * Self.megabyte }

        #expect(tighter.panesToDiscard == [alone.id, sharedOld.id, sharedRecent.id])
    }

    @Test("A pane that may not be discarded keeps its whole process")
    func blockedPaneProtectsItsProcess() {
        let blocked = hidden(processID: 1, minutesAgo: 60, isEvictable: false)
        let sharesBlocked = hidden(processID: 1, minutesAgo: 50)
        let other = hidden(processID: 2, minutesAgo: 10)

        let plan = BrowserHiddenWebViewMemoryBudgetPlanner(budgetMB: 256)
            .plan(panes: [blocked, sharesBlocked, other]) { _ in 400 * Self.megabyte }

        #expect(plan.panesToDiscard == [other.id])
        #expect(plan.remainingHiddenFootprintBytes == 400 * Self.megabyte)
    }

    @Test("Panes without a measurable process are never discarded")
    func skipsUnmeasuredProcesses() {
        let discarded = Pane(id: UUID(), processID: nil, isVisible: false, hiddenAt: now, isEvictable: true)
        let unmeasured = hidden(processID: 1, minutesAgo: 60)
        let measured = hidden(processID: 2, minutesAgo: 10)

        let plan = BrowserHiddenWebViewMemoryBudgetPlanner(budgetMB: 256)
            .plan(panes: [discarded, unmeasured, measured]) { processID in
                processID == 2 ? 400 * Self.megabyte : nil
            }

        #expect(plan.hiddenFootprintBytes == 400 * Self.megabyte)
        #expect(plan.panesToDiscard == [measured.id])
    }

    private func hidden(processID: Int, minutesAgo: Double, isEvictable: Bool = true) -> Pane {
        Pane(
            id: UUID(),
            processID: processID,
            isVisible: false,
            hiddenAt: now.addingTimeInterval(-minutesAgo * 60),
            isEvictable: isEvictable
        )
    }
}
