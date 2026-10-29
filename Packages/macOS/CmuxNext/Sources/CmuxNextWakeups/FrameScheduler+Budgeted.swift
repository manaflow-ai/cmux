extension FrameScheduler {
    /// Only on the scheduler that holds the budget, after every other scheduler on its display: the
    /// tick's budgeted batch. In the tick (``runBudgeted(_:)``), or, under the after-commit placement,
    /// handed to ``defersBudgeted``, which runs it in a turn of its own after the tick's commit.
    func deliverBudgeted(_ tick: FrameTick) {
        guard budget != nil else { return }
        if let defersBudgeted { defersBudgeted(tick) } else { runBudgeted(tick) }
    }

    /// The budgeted batches in class order, each only while its class may run (a held one stays
    /// active and ticks next frame: input pending, or the class's budget spent).
    func runBudgeted(_ tick: FrameTick) {
        guard let budget else { return }
        let order = budgetedOrder
        for workClass in MainWorkClass.budgeted {
            for id in order {
                guard let client = clients[id], client.workClass == workClass, client.isActive else { continue }
                guard budget.mayRun(workClass) else { break }
                fire(client, tick)
                // It ran: the clients of its class that did not get to run go first next frame.
                if clients[id] != nil {
                    budgetedOrder.removeAll { $0 == id }
                    budgetedOrder.append(id)
                }
            }
        }
    }
}
