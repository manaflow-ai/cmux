public import CmuxNextWakeups
public import CmuxUpdater
import Foundation

/// The updater's two network operations, each the cmux form of Chromium's `PostTaskAndReplyWithResult`
/// (base/task/task_runner.h): the network part runs on a nonisolated task, and its result lands as one
/// `visible` task on the app's main-thread scheduler (the card, the sheet and the circle show it), never as
/// an unclassed main-actor resume.
extension UpdaterService {
    /// The app's main-thread scheduler, where the updater's replies land.
    var mainWork: MainWorkScheduler { deadlines.work }

    /// Reads the feed and records what it offers this Mac. Joins a probe
    /// already in flight.
    @discardableResult
    public func probe() -> Task<String?, Never> {
        if let probeTask { return probeTask }
        isProbing = true
        let prober = prober, mainWork = mainWork
        // Sparkle's allowedChannels reads the baked feed, not a test feed: the probe does the same.
        let allowed = identity.feed().channel.allowedSparkleChannels(ring: ring)
        var feed = identity
        if let testFeedURL { feed.infoFeedURL = testFeedURL }
        let probed = feed
        let land: @MainActor @Sendable (Result<UpdateProbeResult, any Error>) -> String? = { [weak self] result in
            self?.landProbe(result) ?? nil
        }
        // task-owner: one feed read off main; it ends once its result landed
        let task = Task { @concurrent () -> String? in
            let result: Result<UpdateProbeResult, any Error>
            do { result = .success(try await prober.probe(probed, allowedChannels: allowed)) } catch { result = .failure(error) }
            return await mainWork.apply(.visible, owner: "UpdaterService.probe") { land(result) }
        }
        probeTask = task
        return task
    }

    /// ``probe()``, then `done` with its failure (nil on success), on main in the task that lands the result:
    /// a caller that acts on the answer needs no main-actor task of its own to wait for it.
    @discardableResult
    func probe(then done: @escaping @MainActor (_ failure: String?) -> Void) -> Task<String?, Never> {
        let task = probe()
        probeWaiters.append(done)
        return task
    }

    /// The probe's result reached main: it is recorded, and the failure's reason is returned (nil on success).
    private func landProbe(_ result: Result<UpdateProbeResult, any Error>) -> String? {
        let failure: String?
        switch result {
        case .success(let probed):
            lastProbe = probed
            lastProbeError = nil
            log.append("probe \(probed.outcome.kind) feed=\(probed.feedURL) items=\(probed.itemCount)")
            failure = nil
        case .failure(let error):
            let reason = String(describing: error)
            lastProbeError = reason
            log.append("probe failed: \(reason)")
            failure = reason
        }
        isProbing = false
        probeTask = nil
        let waiters = probeWaiters
        probeWaiters = []
        for waiter in waiters { waiter(failure) }
        return failure
    }

    /// Opens the other release app (stable <-> NIGHTLY), downloading,
    /// verifying and installing it first when missing. Both apps coexist.
    ///
    /// The switcher reports phases from its own threads: each lands as one `visible` task, in the order
    /// reported (state-audit U1), and a phase that lands after the switch ended (a late progress callback)
    /// finds no switch and is dropped.
    @discardableResult
    public func switchChannel(to target: AppChannelSwitchTarget) throws -> Task<String?, Never> {
        guard identity.channelSwitchTarget == target else { throw UpdaterUnavailable.cannotSwitch(to: target, from: identity.track) }
        if policy.disablesUpdates { throw UpdaterUnavailable(reason: .managedPolicy) }
        if let refusal = managedChannelRefusal(target) { throw refusal }
        if let switchTask { return switchTask }
        channelSwitchError = nil
        let switcher = switcher, mainWork = mainWork
        let phaseOwner = mainWork.board.owner("UpdaterService.channelSwitch.phase")
        let applyPhase: @MainActor @Sendable (AppChannelSwitchPhase) -> Void = { [weak self] phase in
            guard let self, switchTask != nil else { return }
            channelSwitchPhase = phase
        }
        let finish: @MainActor @Sendable (Result<String, any Error>) -> String? = { [weak self] outcome in
            self?.finishSwitch(to: target, outcome) ?? nil
        }
        // task-owner: the switch, off main; it ends once its outcome landed
        let task = Task { @concurrent () -> String? in
            let outcome: Result<String, any Error>
            do {
                let opened = try await switcher.switchTo(target) { phase in
                    mainWork.postFromAnyThread(.visible, owner: phaseOwner) { applyPhase(phase) }
                }
                outcome = .success(String(describing: opened))
            } catch {
                outcome = .failure(error)
            }
            return await mainWork.apply(.visible, owner: "UpdaterService.channelSwitch") { finish(outcome) }
        }
        switchTask = task
        return task
    }

    /// The switch ended: its outcome is logged, a failure kept, and its phase cleared.
    private func finishSwitch(to target: AppChannelSwitchTarget, _ outcome: Result<String, any Error>) -> String? {
        var failure: String?
        switch outcome {
        case .success(let opened):
            log.append("channel switch to \(target.rawValue): \(opened)")
        case .failure(let error):
            failure = String(describing: error)
            channelSwitchError = failure
            log.append("channel switch to \(target.rawValue) failed: \(failure ?? "")")
        }
        channelSwitchPhase = nil
        switchTask = nil
        return failure
    }
}
