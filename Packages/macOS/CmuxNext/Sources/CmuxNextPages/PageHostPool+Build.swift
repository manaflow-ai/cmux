import AppKit
import CmuxNextWakeups

extension PageHostPool {
    var shouldBuild: Bool {
        isLikely && allowsSpare && (madeVisible || !policy.preloadOnMakeVisible) && spare == nil && !building
            && target != nil && claimedHosts.count < policy.maximumHosts
    }

    func scheduleBuild() {
        guard shouldBuild else { return }
        activityMark = activity()
        timer.schedule(after: policy.idleInput) { [weak self] in
            self?.idleDeadline()
        }
    }

    /// Memory pressure is back to normal: build the spare again. A build still in flight started
    /// before the pressure, which closed its spare, so it asks for the next build when it ends.
    func refillSpare() {
        if building { refillAfterBuild = true }
        scheduleBuild()
    }

    private func idleDeadline() {
        guard shouldBuild else { return }
        guard !isTrackingMenu(), activity() == activityMark else {
            scheduleBuild()
            return
        }
        building = true
        // main-hop-allow: build is the pool's main-actor async build, started from its background deadline; every later step waits for its own background task (nextTurn), so the task only starts it
        Task { @MainActor [weak self] in await self?.build() }
    }

    /// Waits for one background task of the pool's scheduler: the next build step runs only once input and
    /// visible work let background work run (Chrome posts spare WebContents work at kBestEffort).
    func nextTurn() async {
        await buildWork.apply(.background, owner: "PageHostPool.build") { () -> Void in }
    }

    private func build() async {
        defer {
            building = false
            if refillAfterBuild {
                refillAfterBuild = false
                scheduleBuild()
            }
        }
        guard let recipe = measure("pool.makeSpare.configure", {
            PageWebView.pooledHostRecipe(.settings, options: options)
        }) else { return }
        await nextTurn()
        let host = measure("pool.makeSpare.create") { PageWebView(recipe: recipe) }
        host.countsTouches = false
        await nextTurn()
        guard isLikely, allowsSpare, spare == nil, let content = target?.contentView else {
            host.close()
            return
        }
        measure("pool.makeSpare.park") { park(host, in: content) }
        spare = host
        await nextTurn()
        guard spare === host else { return }
        measure("pool.makeSpare.load") { host.startLoading() }
        await host.waitUntilLoaded()
        guard spare === host, host.loaded else {
            if spare === host { dropSpare() }
            return
        }
        spareReady = true
        onSpareReady?(host)
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
}
