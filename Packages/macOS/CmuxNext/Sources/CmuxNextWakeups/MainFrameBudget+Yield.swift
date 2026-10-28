extension MainFrameBudget {
    /// Whether the running task should stop between two chunks of its work and post the rest with
    /// ``MainWorkScheduler/postContinuation(_:owner:file:line:_:)`` (p06-scheduler.md, "Posting API"): Blink's
    /// `ShouldYieldForHighPriorityWork` (third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc)
    /// with the rest posted as a `scheduler.yield()` continuation.
    ///
    /// True while a shown frame is late, a person's input is pending or an input response is open. In a budgeted task it is
    /// also true once one more chunk would take the task's class past its share of this frame (``Budgets``), or the frame's
    /// scheduled work past its limit or deadline. The next chunk is taken to cost as much as the last one: the task's own
    /// time since it started or since its last call. So chunked work keeps to its class's share, never to the idle time
    /// ``mayRun(_:)`` gives whole tasks. Ask after each chunk, never before the first, so each task makes progress.
    ///
    /// ```swift
    /// func step() {
    ///     repeat { build.add(rows[next..<min(next + 32, rows.count)]); next += 32 } while next < rows.count && !budget.shouldYield()
    ///     if next < rows.count { mainWork.postContinuation(.visible, owner: owner) { step() } }
    /// }
    /// ```
    public func shouldYield() -> Bool {
        let now = uptimeNanos()
        if isRenderStarved || isInputResponseOpen || inputPending(now) { return true }
        guard let last = open.indices.last, let index = Self.index(open[last].workClass),
              let share = shares.budget(open[last].workClass) else { return false }
        let own = open[last].ownNanos(at: now)
        let chunk = own &- min(open[last].ownAtYieldCheck, own)
        open[last].ownAtYieldCheck = own
        if !underFrameLimit(now &+ chunk) { return true }
        return spentNow(index, workClass: open[last].workClass, now: now) &+ chunk > Self.nanos(share)
    }
}
