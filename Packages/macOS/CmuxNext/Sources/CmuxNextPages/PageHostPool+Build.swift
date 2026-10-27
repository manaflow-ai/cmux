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

    /// The build deadline's action, itself a background task: the recipe is made here, and each later step in a
    /// background task of its own (``step(_:_:)``).
    private func idleDeadline() {
        guard shouldBuild else { return }
        guard !isTrackingMenu(), activity() == activityMark else {
            scheduleBuild()
            return
        }
        guard let recipe = measure("pool.makeSpare.configure", {
            PageWebView.pooledHostRecipe(.settings, options: options)
        }) else { return }
        building = true
        // main-hop-allow: the task runs no build work itself, it only awaits the build's background tasks; each step runs inside its task's body (step(_:_:))
        Task { @MainActor [weak self] in await self?.build(recipe) }
    }

    /// Runs `body`, one step of a build, in the body of one background task of the pool's scheduler: it runs only
    /// once input and visible work let background work run, and the board charges it to `owner` (Chrome posts
    /// spare WebContents work at kBestEffort, content/browser/scheduler/browser_task_queues.h).
    func step<T: Sendable>(_ owner: String, _ body: @escaping @MainActor () -> T) async -> T {
        await deadlines.work.apply(.background, owner: owner) { body() }
    }

    private func build(_ recipe: PooledHostRecipe) async {
        let host = await step("PageHostPool.build.create") { [self] in
            let host = measure("pool.makeSpare.create") { PageWebView(recipe: recipe, deadlines: deadlines) }
            host.countsTouches = false
            return host
        }
        let parked = await step("PageHostPool.build.park") { [self] () -> Bool in
            guard isLikely, allowsSpare, spare == nil, let content = target?.contentView else {
                host.close()
                return endBuild()
            }
            measure("pool.makeSpare.park") { park(host, in: content) }
            spare = host
            return true
        }
        guard parked else { return }
        let loading = await step("PageHostPool.build.load") { [self] () -> Bool in
            guard spare === host else { return endBuild() }
            measure("pool.makeSpare.load") { host.startLoading() }
            return true
        }
        guard loading else { return }
        await host.waitUntilLoaded()
        await step("PageHostPool.build.ready") { [self] in
            defer { _ = endBuild() }
            guard spare === host, host.loaded else {
                if spare === host { dropSpare() }
                return
            }
            spareReady = true
            onSpareReady?(host)
        }
    }

    /// Ends the build, and starts the next one when normal memory came back meanwhile (``refillSpare()``). Returns
    /// false, so a step that ends the build returns it.
    private func endBuild() -> Bool {
        building = false
        if refillAfterBuild {
            refillAfterBuild = false
            scheduleBuild()
        }
        return false
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
