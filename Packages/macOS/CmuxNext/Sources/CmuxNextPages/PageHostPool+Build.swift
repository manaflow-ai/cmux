import AppKit
import CmuxNextCompat
import CmuxNextWakeups

extension PageHostPool {
    /// A WebKit spare cannot serve pages that the configured engine opens in Chromium.
    var canUseSpare: Bool {
        canUseSpare(for: latestClaimOptions)
    }

    func canUseSpare(for options: PageEngineOptions) -> Bool {
        PageServedHosts.pooledDescriptors.contains { engineDecision($0, options).engine == .webKit }
    }

    var shouldBuild: Bool {
        isLikely && spare == nil && !building && target != nil && claimedHosts.count < policy.maximumHosts && canUseSpare
    }

    func scheduleBuild() {
        guard canUseSpare else { return dropSpare() }
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
        let buildOptions = latestClaimOptions
        defer {
            building = false
            // A claim may have changed the engine options while this build was yielding. Once
            // this attempt is no longer marked as active, arm a fresh warmup for the new request.
            if latestClaimOptions != buildOptions, canUseSpare {
                scheduleBuild()
            }
        }
        guard let recipe = measure("pool.makeSpare.configure", {
            PageWebView.pooledHostRecipe(.settings, options: buildOptions)
        }) else { return }
        await Self.nextTurn()
        guard latestClaimOptions == buildOptions, canUseSpare(for: buildOptions) else { return }
        let host = measure("pool.makeSpare.create") { PageWebView(recipe: recipe) }
        host.countsTouches = false
        await Self.nextTurn()
        guard latestClaimOptions == buildOptions, isLikely, canUseSpare(for: buildOptions), spare == nil,
              let content = target?.contentView else {
            host.close()
            return
        }
        measure("pool.makeSpare.park") { park(host, in: content) }
        spare = host
        await Self.nextTurn()
        guard spare === host, latestClaimOptions == buildOptions else {
            if spare === host { dropSpare() }
            return
        }
        measure("pool.makeSpare.load") { host.startLoading() }
        await host.waitUntilLoaded()
        guard spare === host, latestClaimOptions == buildOptions, host.loaded, canUseSpare(for: buildOptions) else {
            if spare === host { dropSpare() }
            return
        }
        suspendAfterPaint(host)
        spareReady = true
        onSpareReady?(host)
    }

    /// Opacity keeps the spare out of sight but leaves its renderer visible to WebKit. Let the
    /// first frame finish, then hide it until a claim; a late paint cannot hide an adopted page.
    func suspendAfterPaint(_ host: PageWebView) {
        host.whenPainted { [weak self, weak host] in
            guard let self, let host, spare === host else { return }
            host.isHidden = true
        }
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
        guard pressureObservation == nil else { return }
        pressureObservation = memoryPressure.observe { [weak self] level in
            if level != .normal { self?.dropSpare() }
        }
    }
}
