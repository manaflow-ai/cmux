package import CmuxNextCompat
package import CmuxNextSettings
import CmuxNextWakeups

/// What one kind of hidden content tells ``ContentDiscardScheduler`` and does for it (the App's
/// page tab store for ``ContentKind/internalPage``).
@MainActor
package protocol ContentDiscardHost: AnyObject {
    /// `key`'s policy while its content is live; nil when there is nothing to discard (it closed or
    /// went already).
    func discardPolicy(of key: String) -> ContentDiscardPolicy?
    /// Why `key`'s content must stay now (an edit not saved, a recording), first reason first.
    func keepReasons(of key: String) -> [CannotDiscardReason]
    /// `key`'s content still draws though hidden (a paint hold keeps the outgoing view on screen).
    func isDrawn(_ key: String) -> Bool
    /// Saves `key`'s state before it goes; nil when it must stay (it showed, changed or got a
    /// reason to stay meanwhile).
    func prepareDiscard(_ key: String) async -> ContentViewState?
    /// Discards `key` now; its release takes the saved state from ``ContentDiscardScheduler/takePrepared(_:)``.
    func commitDiscard(_ key: String)
}

/// When hidden content of one kind is discarded (p07-memory.md 3.C): the proactive discard after each
/// one's ``ContentDiscardPolicy`` (Chrome's proactive_discarding_policy.cc) and, at critical memory
/// pressure, Chrome's urgent pace (urgent_page_discarding_policy.cc). Eligibility, ranking and the
/// next look are ``ContentDiscardPlanner``'s plus the host's keep reasons. Events only: the host
/// reports shows and hides, and one ``DemandTimer`` one-shot says when to look again; nothing polls.
///
/// A show or hide touches only its own item, in the input's turn, and moves the deadline only when
/// that item is due sooner (O(changed)). The whole plan runs when the deadline fires, the pressure
/// changes or a preparation ends. Hidden times and the deadline read the one injected clock.
///
/// A due item is prepared asynchronously (``ContentDiscardHost/prepareDiscard(_:)``); a show
/// meanwhile cancels the preparation, and the host's own check (the content lifecycle's token)
/// refuses a late one. An item whose preparation or release fails while it stays hidden is
/// ``DiscardRule/discardAttempted`` until it shows (``ContentDiscardPlanner/AttemptMarkers``), so the
/// next item takes its slot.
///
/// The Memory Saver mode (`memory.saver`, handed over by the coordinator) scales each policy's
/// timeout for the proactive discard (``MemorySaverMode/proactiveTimeout(_:)``); with the mode off
/// nothing goes proactively, and critical pressure still discards on the urgent pace. A kind made
/// with `urgentAtWarning` (overlay pages: nothing a person made lives in them) takes the urgent pace
/// from warning pressure on.
///
/// A kind whose discard reloads a page (page tabs) also follows `browser.hibernation`
/// (``update(browserHibernation:)``): while it is off or not written, nothing goes on its own, at any
/// pressure, as for browser tabs and the page lifecycle (trunk #25920: a page never reloads unless the
/// person asks).
@MainActor
package final class ContentDiscardScheduler {
    /// One discard per pass (p07-memory.md rule 2), the next a second later while more are due.
    package static let proactivePace = ContentDiscardPlanner.Pace(perPass: 1, interval: 1, minimumHidden: 0)
    /// Chrome's urgent pace; content waits at least 10 s, so the last keystrokes land.
    package static let urgentPace = ContentDiscardPlanner.Pace(perPass: 1, interval: ContentDiscardPlanner.Pace.chromeUrgent.interval,
                                                               minimumHidden: 10)
    /// How soon a due item that still draws is looked at again (backing off while it stays).
    package static let drawnRecheck: Double = 1

    package let kind: ContentKind
    /// Whether warning pressure runs the urgent pace too, not only critical pressure.
    package let urgentAtWarning: Bool
    package weak var host: (any ContentDiscardHost)?
    package private(set) var pressure: MemoryPressureLevel = .normal
    /// Why each kept item stays (the first reason), for `debug.discards`.
    package private(set) var exemptions: [String: CannotDiscardReason] = [:]
    /// Seconds from the last arming until the deadline; nil while none is armed.
    package private(set) var nextCheck: Double?
    package private(set) var discardedCount = 0
    /// The `memory.saver` mode the proactive timeouts follow.
    package private(set) var saverMode: MemorySaverMode = .medium
    /// An item was discarded (the memory histograms count it).
    package var onDiscard: () -> Void = {}
    /// The hidden items whose discard was tried and did not finish since they last showed.
    package private(set) var discardAttempts = ContentDiscardPlanner.AttemptMarkers()
    /// Why no hidden item goes on its own now, at any pressure (`browser.hibernation` off: `disabled`;
    /// not written: `keepsState`); nil while items may go. Only a kind that follows the setting sets it
    /// (``update(browserHibernation:)``).
    package private(set) var keptBySetting: CannotDiscardReason?

    private let planner = ContentDiscardPlanner()
    private let deadline: DemandTimer
    /// Time on the injected clock since the scheduler was made: hidden times and the deadline's.
    private let elapsed: () -> Duration
    /// When the armed deadline fires, on ``elapsed``; nil while none is armed.
    private var deadlineAt: Duration?
    private var hiddenAt: [String: Duration] = [:]
    private var preparing: [String: Task<Void, Never>] = [:]
    private var prepared: [String: ContentViewState] = [:]
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - kind: The kind of content it discards.
    ///   - memory: The app's memory coordinator, which hands it each pressure level; nil keeps it at
    ///     normal (``update(pressure:)``).
    ///   - urgentAtWarning: Whether warning pressure runs the urgent pace too (overlay pages).
    ///   - clock: The one clock of hidden times and the deadline.
    package init(kind: ContentKind, memory: (any MemoryConsumerRegistry)? = nil, urgentAtWarning: Bool = false,
                 clock: any Clock<Duration> = ContinuousClock()) {
        self.kind = kind
        self.urgentAtWarning = urgentAtWarning
        deadline = DemandTimer(owner: "ContentDiscardScheduler.\(kind.rawValue)", clock: clock)
        elapsed = Self.stopwatch(clock)
        memoryRegistration = memory.map {
            MemoryConsumerRegistration(name: "\(kind.rawValue)-discards", traits: Self.memoryTraits, consumer: self, registry: $0)
        }
    }

    /// Time on `clock` since this call.
    private static func stopwatch<C: Clock<Duration>>(_ clock: C) -> () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    package var hasDeadline: Bool { deadline.isScheduled }

    /// Whether the pressure now runs the urgent pace.
    private var isUrgent: Bool { pressure == .critical || (urgentAtWarning && pressure == .warning) }

    /// Waits until the preparations running now ended (tests).
    package func settled() async {
        for task in Array(preparing.values) { await task.value }
    }

    /// `key` shows: it is not due, and a preparation for it stops. The deadline stays for the other
    /// hidden items (a look with nothing due finds nothing) and goes with the last one.
    package func contentDidShow(_ key: String) {
        hiddenAt[key] = nil
        exemptions[key] = nil
        discardAttempts.clear(key)
        preparing.removeValue(forKey: key)?.cancel()
        prepared[key] = nil
        if hiddenAt.isEmpty, preparing.isEmpty { disarm() }
    }

    /// `key` stopped showing: the deadline moves sooner when `key` is due before it.
    package func contentDidHide(_ key: String) {
        hiddenAt[key] = elapsed()
        guard let host, let timeout = dueAfter(key, host: host) else { return }
        arm(after: isUrgent ? min(timeout, Self.urgentPace.minimumHidden) : timeout, onlySooner: true)
    }

    /// The state `key` goes with, for the host's release; nil for a discard nobody prepared (the
    /// person's own).
    package func takePrepared(_ key: String) -> ContentViewState? { prepared.removeValue(forKey: key) }

    /// The host discarded `key`.
    package func noteDiscarded(_ key: String) {
        hiddenAt[key] = nil
        discardAttempts.clear(key)
        discardedCount += 1
        onDiscard()
    }

    /// The host's release of hidden `key` let nothing go (it started moving, or it is in use): it
    /// stays until it shows.
    package func noteDiscardFailed(_ key: String) {
        guard hiddenAt[key] != nil else { return }
        discardAttempts.mark(key)
    }

    package func update(pressure: MemoryPressureLevel) {
        guard pressure != self.pressure else { return }
        self.pressure = pressure
        replan()
    }

    /// Starts the preparation of the next due item and arms one deadline for the one after.
    package func replan() {
        guard let host else { return disarm() }
        // Content that closed or went has nothing left to discard, and no mark.
        for key in hiddenAt.keys where host.discardPolicy(of: key) == nil {
            hiddenAt[key] = nil
            discardAttempts.clear(key)
        }
        let current = elapsed()
        let reason: DiscardReason = isUrgent ? .urgent : .proactive
        var next: Double?
        var timed: [ContentDiscardPlanner.TimedCandidate] = []
        exemptions = [:]
        for (key, at) in hiddenAt where preparing[key] == nil {
            if let kept = keptBySetting {
                // Only a change of the setting lets it go (``update(browserHibernation:)``): no deadline.
                exemptions[key] = kept
                continue
            }
            guard let timeout = dueAfter(key, host: host) else { continue }
            let hidden = (current - at) / .seconds(1)
            if host.isDrawn(key) {
                exemptions[key] = .visible
                next = min(next ?? .infinity, max(Self.drawnRecheck, hidden - timeout, timeout - hidden))
            } else if let kept = host.keepReasons(of: key).first {
                // No event says the edit or the recording ended: ask again one policy time later.
                exemptions[key] = kept
                next = min(next ?? .infinity, max(timeout, Self.drawnRecheck))
            } else {
                var candidate = ContentDiscardPlanner.Candidate(key: key, kind: kind, hiddenFor: hidden)
                candidate.discardAttempted = discardAttempts.contains(key)
                timed.append(ContentDiscardPlanner.TimedCandidate(candidate, timeout: timeout))
            }
        }
        let plan = planner.plan(.fallback, for: reason, pace: reason == .urgent ? Self.urgentPace : Self.proactivePace, timed: timed)
        exemptions.merge(plan.exemptions) { first, _ in first }
        for key in plan.due { prepare(key, host: host) }
        if let wait = [next, plan.nextCheck].compactMap({ $0 }).min() { arm(after: wait, onlySooner: false) } else { disarm() }
    }

    /// Seconds hidden before `key` is due: its policy's timeout under urgent pressure (the urgent
    /// pass), else that timeout in the Memory Saver mode; nil when it is not due at all now (it has
    /// no policy, the mode is off below urgent pressure, or ``keptBySetting`` keeps every item).
    private func dueAfter(_ key: String, host: any ContentDiscardHost) -> Double? {
        guard keptBySetting == nil, let timeout = host.discardPolicy(of: key)?.timeout else { return nil }
        if isUrgent { return timeout }
        return saverMode.proactiveTimeoutScale.map { timeout * $0 }
    }

    /// `browser.hibernation` changed, for a kind whose discard reloads a page (page tabs): with it off
    /// (`disabled`) or not written (`keepsState`, `BrowserHibernationSetting.discardsAutomatically`) no
    /// hidden item goes on its own, at any memory pressure, as ``HibernationPlanner`` keeps browser tabs
    /// and ``PageLifecyclePlanner`` keeps pages then; a preparation running now stops, as a show stops it.
    /// The next look runs on the deadline, never in the turn of the settings flush.
    package func update(browserHibernation setting: BrowserHibernationSetting) {
        let kept: CannotDiscardReason? = if !setting.isEnabled {
            .disabled
        } else if !setting.discardsAutomatically {
            .keepsState
        } else {
            nil
        }
        guard kept != keptBySetting else { return }
        keptBySetting = kept
        if kept != nil {
            for task in preparing.values { task.cancel() }
            preparing.removeAll()
            prepared.removeAll()
        }
        if !hiddenAt.isEmpty { arm(after: 0, onlySooner: false) }
    }

    /// Arms the one deadline `wait` seconds from now; with `onlySooner`, only when the armed one is later.
    private func arm(after wait: Double, onlySooner: Bool) {
        let at = elapsed() + .milliseconds(Int64(wait * 1000))
        if onlySooner, let armed = deadlineAt, armed <= at { return }
        deadlineAt = at
        nextCheck = wait
        // 50 ms past the due time, so the look finds the item due, not a hair short of it.
        deadline.scheduleOnMain(after: .milliseconds(Int64(wait * 1000) + 50)) { [weak self] in
            self?.deadlineAt = nil
            self?.replan()
        }
    }

    private func disarm() {
        deadlineAt = nil
        nextCheck = nil
        deadline.cancel()
    }

    private func prepare(_ key: String, host: any ContentDiscardHost) {
        // task-owner: preparing[key]; cancelled when the item shows, dropped when it ends
        preparing[key] = Task { [weak self, weak host] in
            let state = await host?.prepareDiscard(key)
            guard let self, !Task.isCancelled else { return }
            preparing[key] = nil
            if let state, let host {
                prepared[key] = state
                host.commitDiscard(key)
                prepared[key] = nil
            } else if host != nil, hiddenAt[key] != nil {
                // It must stay though still hidden: the next pass gives its slot to the next item.
                discardAttempts.mark(key)
            }
            replan()
        }
    }
}

// One lossy consumer of the app's memory coordinator, as browser hibernation is (Chrome's
// urgent_page_discarding_policy.cc: lossy, not stateful): the level picks the proactive or the
// urgent pass, the Memory Saver mode the proactive timeouts, and the critical limit's release slice
// runs one urgent pass.
extension ContentDiscardScheduler: MemoryLevelConsumer, MemorySaverModeConsumer {
    package static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .reads, retention: .lossy, recreateCost: .expensive,
        releaseCPUCost: .high, isStateful: false, supportsMemoryLimit: false)

    package func memoryLevelDidChange(_ level: MemoryPressureLevel) { update(pressure: level) }

    /// The next look runs on the deadline, never in the turn of the change (an action's or a
    /// settings flush's): it re-times every hidden item against the new mode.
    package func memorySaverModeDidChange(_ mode: MemorySaverMode) {
        guard mode != saverMode else { return }
        saverMode = mode
        if !hiddenAt.isEmpty { arm(after: 0, onlySooner: false) }
    }
    package func updateMemoryLimit(_ limit: MemoryLimit) {}

    package func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        if slice.limit.isCritical { replan() }
        return .done
    }

    /// Unknown: the content's memory is not sampled per item yet.
    package var memoryUsage: MemoryUsage? { nil }
}
