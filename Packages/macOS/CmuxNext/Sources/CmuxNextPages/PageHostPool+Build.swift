import AppKit
import CmuxNextWakeups

/// Building the spare: only while a shell page is likely, after a whole quiet period, one step per
/// run-loop turn (configure, create, park, launch the WebContent process with an empty document,
/// start the load), each step measured, so no frame holds more than one step. The first build in a
/// process also pays WebKit's one-time cold start (36-48 ms in one step on cmux-lawrence-2): an
/// exception the split cannot remove. Step p95 per build: see PageHostPool.
extension PageHostPool {
    var shouldBuild: Bool {
        isLikely && spare == nil && !building && target != nil && claimedHosts.count < policy.maximumHosts
    }

    /// Whether the pool may build a spare now (likely, none parked, under the host limit).
    public var mayBuild: Bool { shouldBuild }

    /// Arms the idle deadline: it builds only after a whole quiet period (no change of the app's
    /// activity counters: input, animation frames, terminal output; no menu tracking).
    func scheduleBuild() {
        guard shouldBuild else { return }
        watchMemoryPressure()
        armIdle()
    }

    private func armIdle() {
        activityMark = activity()
        timer.schedule(after: policy.idleInput) { @MainActor [weak self] in self?.idleDeadline() }
    }

    private func idleDeadline() {
        guard shouldBuild else { return }
        guard !isTrackingMenu(), activity() == activityMark else { return armIdle() }
        building = true
        // task-owner: one spare build; each step is its own run-loop turn so no frame holds two
        Task { @MainActor [weak self] in await self?.build() }
    }

    /// The next run-loop turn of the main thread (the frame in between can commit).
    static func nextTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
    }

    private func build() async {
        defer { building = false }
        guard let recipe = measure("pool.makeSpare.configure", { PageWebView.pooledHostRecipe(served, options: options) })
        else { return }
        await Self.nextTurn()
        let host = measure("pool.makeSpare.create") { PageWebView(recipe: recipe) }
        host.countsTouches = false
        await Self.nextTurn()
        guard isLikely, spare == nil, let content = target?.contentView else {
            host.close()
            return
        }
        measure("pool.makeSpare.park") { park(host, in: content) }
        spare = host
        await Self.nextTurn()
        guard spare === host else { return }
        // The WebContent process launch and the page load in separate turns.
        measure("pool.makeSpare.launch") { host.warmUpProcess() }
        await Self.nextTurn()
        guard spare === host else { return }
        measure("pool.makeSpare.load") { host.startLoading() }
        await host.waitUntilLoaded()
        // A shell that did not load or never boots (a missing build) leaves no spare: callers open cold.
        guard host.isLoaded, await host.preloadShellPages() else {
            if spare === host { dropSpare() }
            return
        }
        guard spare === host else { return }
        spareReady = true
        onSpareReady?(host)
        prepareSpare()
    }

    private func measure<T>(_ name: String, _ body: () -> T) -> T {
        let start = ContinuousClock.now
        let value = body()
        let milliseconds = Self.milliseconds(since: start)
        spans.append((name, milliseconds))
        if spans.count > Self.maximumRecords { spans.removeFirst(spans.count - Self.maximumRecords) }
        onSpan?(name, milliseconds)
        return value
    }

    private func watchMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            // crash-allow: the source's queue is .main, so the handler runs on the main thread.
            MainActor.assumeIsolated { self?.dropSpare() }
        }
        source.resume()
        memoryPressure = source
    }
}
