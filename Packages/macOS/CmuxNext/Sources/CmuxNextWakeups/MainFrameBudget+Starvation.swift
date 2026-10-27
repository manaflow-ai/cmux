extension MainFrameBudget {
    /// Whether a shown frame is late and the guard holds work for it (``RenderStarvationGuard``):
    /// ``mayRun(_:)`` then refuses every budgeted class, which holds posted work, posted deadlines and
    /// every budgeted queue. A source outside the budget reads it before it starts (IdleScheduler's
    /// idle periods, p06-scheduler task 005). False without a guard, or when the guard only reports.
    public var isRenderStarved: Bool {
        guard let starvation else { return false }
        return starvation.isStarved() && starvation.holdsWork
    }

    /// ``mayRun(_:)``'s first rule: a task of the budgeted class at `index` waits while a shown frame
    /// is late (counted on the guard).
    func heldForLateFrame(_ index: Int) -> Bool {
        guard isRenderStarved else { return false }
        starvation?.noteHeld(index)
        return true
    }
}
