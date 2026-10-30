extension SidebarDocStore {
    /// Nothing this store asked the daemon is still on its way: every change (move, pin, apply)
    /// and every adopt it sent has its reply or was given up, and no document load runs (a change
    /// left unanswered is settled by the next load). The daemon committed each answered change
    /// before its reply, so a write sent after this lands after them; with the store's events
    /// applied through a barrier taken after this (`DaemonStore.appliedThrough`), the document
    /// holds their echoes too.
    public var isSettled: Bool { inFlight == 0 && !loading }

    /// Returns once ``isSettled`` holds: now, or when the last reply or load in flight ends.
    /// Event-driven (each reply and load end resumes the waiters), no polling and no quiet window.
    /// A classic import waits here so a workspace's group write comes after its slot move: a slot
    /// move landing after it would take the workspace out of its group again (#28425).
    public func settled() async {
        while !isSettled {
            await withCheckedContinuation { waiter in
                settledWaiters.append(waiter)
                onSettledWait?()
            }
        }
    }

    /// What keeps ``isSettled`` false, for a test's hang report: the changes and adopts in flight, a
    /// running load, the changes a load must settle, and who waits.
    var pendingDescription: String {
        "\(inFlight) sidebar document changes or adopts unanswered, load running: \(loading), "
            + "settled by the next load: \(unansweredCount), waiting in settled(): \(settledWaiters.count)"
    }

    /// Someone waits in ``settled()`` (a test seam: a live-daemon test releases the replies it holds).
    var waitsForSettled: Bool { !settledWaiters.isEmpty }

    /// One change or adopt got its reply (or was given up).
    func answered() {
        inFlight -= 1
        resumeIfSettled()
    }

    /// Resumes everyone in ``settled()`` once nothing is in flight.
    func resumeIfSettled() {
        guard isSettled, !settledWaiters.isEmpty else { return }
        let waiting = settledWaiters
        settledWaiters = []
        for waiter in waiting { waiter.resume() }
    }
}
