public import CmuxNextWakeups
public import CmuxUpdater
import CmuxNextCompat
import Foundation

/// The updater's two network operations, each the cmux form of Chromium's `PostTaskAndReplyWithResult`
/// (base/task/task_runner.h): the network part runs on a nonisolated task, and its result lands as one
/// classed task on the app's main-thread scheduler (the card, the sheet and the circle show it), never as
/// an unclassed main-actor resume.
extension UpdaterService {
    /// The app's main-thread scheduler, where the updater's replies land.
    var mainWork: MainWorkScheduler { deadlines.work }

    /// Reads the feed and records what it offers this Mac, then calls `done` with its failure (nil on
    /// success) on main, in the task that lands the answer: a caller that acts on the answer needs no
    /// main-actor task of its own to wait for it. Joins a probe already in flight.
    ///
    /// The answer lands in the most urgent class a caller asked for (`workClass`): `userBlocking` for a
    /// read the person waits on (the install click, their own check), `visible` for a scheduled one,
    /// `automation` for the CLI's. A caller more urgent than an answer already queued on main lands it in
    /// its own class, so a deadline the person waits on never runs before an answer that came first.
    @discardableResult
    public func probe(_ workClass: BudgetedWorkClass, then done: (@MainActor (_ failure: String?) -> Void)? = nil) -> Task<String?, Never> {
        if var flight = probeFlight {
            if let done { flight.waiters.append(done) }
            let raised = workClass.workClass < flight.landing.workClass
            if raised { flight.landing = workClass }
            probeFlight = flight
            if raised, flight.arrived != nil {
                mainWork.post(workClass, owner: "UpdaterService.probe") { [weak self] in self?.landArrivedProbe() }
            }
            return flight.task
        }
        isProbing = true
        let prober = prober
        // Sparkle's allowedChannels reads the baked feed, not a test feed: the probe does the same.
        let allowed = identity.feed().channel.allowedSparkleChannels(ring: ring)
        var feed = identity
        if let testFeedURL { feed.infoFeedURL = testFeedURL }
        let probed = feed
        let arrive: @MainActor @Sendable (Result<UpdateProbeResult, any Error>) async -> Void = { [weak self] result in
            await self?.probeArrived(result)
        }
        // task-owner: one feed read off main; it ends once its result landed
        let task = Task { @concurrent () -> String? in
            let result: Result<UpdateProbeResult, any Error>
            do { result = .success(try await prober.probe(probed, allowedChannels: allowed)) } catch { result = .failure(error) }
            await arrive(result)
            return UpdaterService.failureReason(result)
        }
        probeFlight = ProbeFlight(task: task, waiters: done.map { [$0] } ?? [], landing: workClass)
        return task
    }

    /// The read's answer reached main: it waits there for one task of the flight's class.
    private func probeArrived(_ result: Result<UpdateProbeResult, any Error>) async {
        guard let landing = probeFlight?.landing else { return }
        probeFlight?.arrived = result
        _ = await mainWork.apply(landing, owner: "UpdaterService.probe") { [weak self] in self?.landArrivedProbe() }
    }

    /// Lands the answer that reached main, once (in its class's task, or in a more urgent caller's): it is
    /// recorded, and every waiter gets its failure.
    private func landArrivedProbe() {
        guard let flight = probeFlight, let result = flight.arrived else { return }
        probeFlight = nil
        isProbing = false
        switch result {
        case .success(let probed):
            lastProbe = probed
            lastProbeError = nil
            log.append("probe \(probed.outcome.kind) feed=\(probed.feedURL) items=\(probed.itemCount)")
        case .failure(let error):
            let reason = String(describing: error)
            lastProbeError = reason
            log.append("probe failed: \(reason)")
        }
        let failure = Self.failureReason(result)
        for waiter in flight.waiters { waiter(failure) }
    }

    /// The failure's reason, nil on success.
    private nonisolated static func failureReason(_ result: Result<UpdateProbeResult, any Error>) -> String? {
        guard case .failure(let error) = result else { return nil }
        return String(describing: error)
    }

    /// Opens the other release app (stable <-> NIGHTLY), downloading,
    /// verifying and installing it first when missing. Both apps coexist.
    ///
    /// The switcher reports phases from its own threads, one per download write. Only the newest reaches
    /// main ("bufferingNewest(1)", as Chromium hands download progress to the UI on a period, not per
    /// write: components/download/internal/common/download_file_impl.cc, `kUpdatePeriodMs`): a phase
    /// replaces one not applied yet, and one `visible` task at a time applies it. A phase that lands after
    /// the switch ended (a late progress callback) finds no switch and is dropped.
    @discardableResult
    public func switchChannel(to target: AppChannelSwitchTarget) throws -> Task<String?, Never> {
        guard identity.channelSwitchTarget == target else { throw UpdaterUnavailable.cannotSwitch(to: target, from: identity.track) }
        if policy.disablesUpdates { throw UpdaterUnavailable(reason: .managedPolicy) }
        if let refusal = managedChannelRefusal(target) { throw refusal }
        if let switchTask { return switchTask }
        channelSwitchError = nil
        let switcher = switcher, mainWork = mainWork
        let phaseOwner = mainWork.board.owner("UpdaterService.channelSwitch.phase")
        let phases = SwitchPhaseMailbox()
        let applyPhase: @MainActor @Sendable () -> Void = { [weak self] in
            guard let phase = phases.take(), let self, switchTask != nil else { return }
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
                    guard phases.put(phase) else { return }
                    mainWork.postFromAnyThread(.visible, owner: phaseOwner, applyPhase)
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

/// A feed read in flight (``UpdaterService/probe(_:then:)``): its task, who waits for its answer, the class
/// the answer lands in, and the answer once it reached main and waits to land.
struct ProbeFlight {
    let task: Task<String?, Never>
    var waiters: [@MainActor (_ failure: String?) -> Void]
    var landing: BudgetedWorkClass
    var arrived: Result<UpdateProbeResult, any Error>?
}

/// The channel switch's newest phase on its way to main: a phase replaces one not applied yet, and only the
/// phase that finds no apply in flight asks for one (``put(_:)`` returns true), so the switcher's threads
/// post at most one main-thread task at a time however often the download reports.
nonisolated final class SwitchPhaseMailbox: Sendable {
    private struct Slot {
        var phase: AppChannelSwitchPhase?
        var applyPosted = false
    }

    private let slot = Mutex(Slot())

    /// Keeps `phase` as the newest; true when the caller must post the one apply that takes it.
    func put(_ phase: AppChannelSwitchPhase) -> Bool {
        slot.withLock { slot in
            slot.phase = phase
            if slot.applyPosted { return false }
            slot.applyPosted = true
            return true
        }
    }

    /// Takes the newest phase on main; the next ``put(_:)`` posts again.
    func take() -> AppChannelSwitchPhase? {
        slot.withLock { slot in
            let phase = slot.phase
            slot = Slot()
            return phase
        }
    }
}
