import AppKit
import CmuxNextWakeups

extension PageHostPool {
    var shouldBuild: Bool {
        isLikely && spare == nil && !building && target != nil && claimedHosts.count < policy.maximumHosts
    }

    func scheduleBuild() {
        guard shouldBuild else { return }
        watchMemoryPressure()
        activityMark = activity()
        timer.schedule(after: policy.idleInput) { @MainActor [weak self] in
            self?.idleDeadline()
        }
    }

    private func idleDeadline() {
        guard shouldBuild else { return }
        guard !isTrackingMenu(), activity() == activityMark else {
            scheduleBuild()
            return
        }
        building = true
        Task { @MainActor [weak self] in await self?.build() }
    }

    static func nextTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
    }

    private func build() async {
        defer { building = false }
        guard let recipe = measure("pool.makeSpare.configure", {
            PageWebView.pooledHostRecipe(.settings, options: options)
        }) else { return }
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

    private func watchMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.dropSpare() }
        }
        source.resume()
        memoryPressure = source
    }
}
