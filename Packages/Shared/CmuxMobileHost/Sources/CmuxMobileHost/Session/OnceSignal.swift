import CmuxLink

/// Fires once; `wait()` returns after the first `fire()`. Used to bound a
/// best-effort notice by a grace period on the injected clock.
actor OnceSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        guard !fired else { return }
        fired = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Runs `work` unstructured and returns when it finishes or `grace`
    /// passes, whichever comes first. Neither branch is awaited past that,
    /// so a peer that stopped reading cannot hold the caller.
    static func bounded(_ grace: Duration, clock: LinkClock, _ work: @escaping @Sendable () async -> Void) async {
        let signal = OnceSignal()
        Task {
            await work()
            await signal.fire()
        }
        let timer = Task {
            try? await clock.sleep(for: grace)
            await signal.fire()
        }
        await signal.wait()
        timer.cancel()
    }
}
