package import CmuxNextCompat
package import CmuxNextWakeups

/// A window that keeps hidden workspaces mounted and paused (the App's `WindowController`).
@MainActor
package protocol ParkedWorkspaceHolder: AnyObject {
    /// Whether the window is on screen: shown, not minimized and not fully covered. Pressure tears
    /// down the workspaces of windows off screen first.
    var showsOnScreen: Bool { get }
    /// Whether parked workspace `id` must stay mounted now: it draws on screen beside the shown one
    /// (`sidebar.multiView`), or a top page covers it as the window's own workspace.
    func keepsParkedWorkspace(_ id: String) -> Bool
    /// Tears parked workspace `id` down (views, pane controllers, observations); it mounts again
    /// when shown. False when the holder no longer parks it.
    @discardableResult
    func discardParkedWorkspace(_ id: String) -> Bool
}

/// The one-shot deadline of the budget's next look: a `background` ``MainDeadline`` in the app
/// (a teardown nobody sees waits behind input and visible work), a fake in tests.
@MainActor
package protocol ParkedWorkspaceDeadline: AnyObject {
    /// Runs `action` once after `delay`, replacing a pending deadline.
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void)
    /// Drops the pending deadline.
    func cancel()
}

extension MainDeadline: ParkedWorkspaceDeadline {}

/// Holds the parked workspaces of every window to the Mac's budget (p07-memory.md 3.B
/// `parkedWorkspaces`, 3.C "Hidden workspace past the parked budget or idle timeout").
///
/// - **Budget.** At most ``capacity`` parked workspaces across all windows, scaled by the memory
///   limit (critical: none); with no budget (`memoryDiscardParkedWorkspaces` off) only critical
///   pressure tears down. Past it the least recently parked one that may go is torn down, as
///   Chrome's `FrameEvictionManager` culls the oldest unlocked saved frame
///   (components/viz/client/frame_eviction_manager.cc, `CullUnlockedFrames`): one its holder keeps
///   (a `sidebar.multiView` companion on screen, the workspace under a top page) still counts.
/// - **Idle timeout.** A parked workspace hidden ``idleTimeout`` goes even within the budget, as
///   Chrome's proactive discard takes tabs hidden past their time
///   (chrome/browser/resource_coordinator/tab_lifecycle_unit.cc). The Memory Saver mode
///   (`memory.saver`) scales it as Chrome's memory_saver_mode_policy.cc scales its tab timers
///   (``MemorySaverMode/proactiveTimeout(_:)``); off, only the budget and pressure tear down.
/// - **Pressure.** A ``MemoryConsumer`` of the app's coordinator: a lower limit is released by
///   ``releaseMemory(within:)``, one teardown per slice, workspaces of windows off
///   screen first, as Chrome's urgent page discarding takes hidden tabs before visible ones
///   (chrome/browser/performance_manager/policies/urgent_page_discarding_policy.cc).
///
/// Events only: parks, shows, closes, a holder that stops keeping a workspace
/// (``keepingDidChange(in:)``), and one ``ParkedWorkspaceDeadline`` for the next look; a kept
/// workspace arms none.
/// Each look (``plan()``) tears down at most one workspace, after the switch's turn, never in it,
/// and asks for the next look on a later task while more are due (p07-memory.md rule 2).
@MainActor
package final class ParkedWorkspaceBudget {
    /// How the budget lists a consumer for the coordinator: a workspace view tree is large, costly
    /// to mount again, and loses its view-only state.
    package static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .none, retention: .lossy, recreateCost: .expensive,
        releaseCPUCost: .high, isStateful: true, supportsMemoryLimit: true)

    /// Parked workspaces across all windows at normal pressure (`SubsystemBudget.parkedWorkspaces`);
    /// `Int.max` with no budget.
    package let capacity: Int
    /// How long a parked workspace may stay hidden in the current Memory Saver mode; nil: only the
    /// budget and pressure tear down.
    package var idleTimeout: Duration? { mediumIdleTimeout.flatMap { saverMode.proactiveTimeout($0) } }
    /// The `memory.saver` mode the idle timeout follows (the coordinator hands it over).
    package private(set) var saverMode: MemorySaverMode = .medium
    /// The coordinator's limit; ``capacity`` scaled by it is the budget now.
    package private(set) var limit: MemoryLimit = .default
    /// Workspaces torn down so far (tests, diagnostics).
    package private(set) var discardedCount = 0

    private struct Key: Hashable {
        let holder: ObjectIdentifier
        let workspace: String
    }

    private struct Entry {
        weak var holder: (any ParkedWorkspaceHolder)?
        let key: Key
        /// When it was parked, or stopped being kept (a kept workspace is in use).
        var since: ContinuousClock.Instant
        /// Least recently parked first.
        var serial: UInt64
        /// Its holder kept it when last asked.
        var kept: Bool
    }

    /// The idle timeout in the default mode, medium.
    private let mediumIdleTimeout: Duration?
    private var entries: [Key: Entry] = [:]
    private var serial: UInt64 = 0
    private let deadline: any ParkedWorkspaceDeadline
    private let now: () -> ContinuousClock.Instant
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - capacity: Parked workspaces across all windows at normal pressure; nil for no budget (only
    ///     critical pressure tears down).
    ///   - idleTimeout: How long one may stay hidden in Memory Saver's medium mode; nil for no timeout.
    ///   - deadline: The one deadline of the next look.
    ///   - memory: The app's memory coordinator; nil keeps the limit at 100 %.
    ///   - now: The clock of hidden times (tests set it).
    package init(capacity: Int?, idleTimeout: Duration?, deadline: any ParkedWorkspaceDeadline,
                 memory: (any MemoryConsumerRegistry)? = nil, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.capacity = capacity.map { max($0, 0) } ?? .max
        mediumIdleTimeout = idleTimeout
        self.deadline = deadline
        self.now = now
        memoryRegistration = memory.map {
            MemoryConsumerRegistration(name: "parked-workspaces", traits: Self.memoryTraits, consumer: self, registry: $0)
        }
    }

    /// The budget at the current limit.
    package var currentCapacity: Int { limit.scale(capacity) }

    /// Parked workspaces whose holder is alive.
    package var parkedCount: Int { entries.values.count(where: { $0.holder != nil }) }

    /// `holder` parked workspace `id` (it stopped showing): it is the most recently parked, and the
    /// next look runs after this turn.
    package func didPark(_ id: String, in holder: any ParkedWorkspaceHolder) {
        let key = Key(holder: ObjectIdentifier(holder), workspace: id)
        serial &+= 1
        entries[key] = Entry(holder: holder, key: key, since: now(), serial: serial, kept: holder.keepsParkedWorkspace(id))
        if lookCanTearDown { deadline.schedule(after: .zero) { [weak self] in self?.plan() } }
    }

    /// `holder` may keep other workspaces now (it arranged its content: a `sidebar.multiView` set
    /// changed, a top page opened or closed). One it stopped keeping is hidden from now: it becomes
    /// the most recently parked, and the next look runs after this turn. O(parked workspaces).
    package func keepingDidChange(in holder: any ParkedWorkspaceHolder) {
        let id = ObjectIdentifier(holder), at = now()
        var released = false
        for key in entries.keys.filter({ $0.holder == id }) {
            if refreshKept(key, at: at) { released = true }
        }
        if released, lookCanTearDown { deadline.schedule(after: .zero) { [weak self] in self?.plan() } }
    }

    /// Whether a look may tear anything down: past the budget, or with a timeout to watch. With no
    /// budget at normal pressure a park arms nothing.
    private var lookCanTearDown: Bool {
        idleTimeout != nil || entries.count > currentCapacity
    }

    /// `holder` no longer parks workspace `id`: it shows again, closed, left the window or was torn down.
    package func forget(_ id: String, in holder: any ParkedWorkspaceHolder) {
        entries[Key(holder: ObjectIdentifier(holder), workspace: id)] = nil
        if entries.isEmpty { deadline.cancel() }
    }

    /// `holder` closed: none of its workspaces count any more.
    package func forgetAll(in holder: any ParkedWorkspaceHolder) {
        let id = ObjectIdentifier(holder)
        entries = entries.filter { $0.key.holder != id }
        if entries.isEmpty { deadline.cancel() }
    }

    /// One look: tears down the least recently parked workspace that may go while over the budget,
    /// else the longest hidden one past the idle timeout, and arms the next look for when the
    /// longest hidden one comes due. A workspace its holder keeps is in use: it never goes and arms
    /// no look; its hidden time starts when it stops being kept.
    package func plan() {
        let at = now()
        dropClosedHolders()
        for key in Array(entries.keys) { refreshKept(key, at: at) }
        // Least recently parked first, so the first one not kept is also the one hidden longest.
        let oldest = entries.values.filter { !$0.kept }.min { $0.serial < $1.serial }
        if entries.count > currentCapacity, let oldest { return discardAndLookAgain(oldest) }
        guard let idleTimeout, let oldest else { return deadline.cancel() }
        let remaining = idleTimeout - (at - oldest.since)
        if remaining <= .zero { return discardAndLookAgain(oldest) }
        deadline.schedule(after: remaining) { [weak self] in self?.plan() }
    }

    /// Asks the holder whether it keeps `key` now. True when it stopped keeping it: its hidden time
    /// starts at `at` and it becomes the most recently parked.
    @discardableResult
    private func refreshKept(_ key: Key, at: ContinuousClock.Instant) -> Bool {
        guard let entry = entries[key] else { return false }
        let kept = isKept(entry)
        entries[key]?.kept = kept
        guard entry.kept, !kept else { return false }
        serial &+= 1
        entries[key]?.serial = serial
        entries[key]?.since = at
        return true
    }

    /// One teardown per look; the next look, when one may tear down, runs on a later task.
    private func discardAndLookAgain(_ entry: Entry) {
        discard(entry)
        if lookCanTearDown { deadline.schedule(after: .zero) { [weak self] in self?.plan() } }
    }

    /// The live entries, least recently parked first; entries of closed holders go.
    private func liveEntriesLeastRecentFirst() -> [Entry] {
        dropClosedHolders()
        return entries.values.sorted { $0.serial < $1.serial }
    }

    private func dropClosedHolders() {
        entries = entries.filter { $0.value.holder != nil }
    }

    private func isKept(_ entry: Entry) -> Bool {
        entry.holder?.keepsParkedWorkspace(entry.key.workspace) ?? false
    }

    private func discard(_ entry: Entry) {
        entries[entry.key] = nil
        if entry.holder?.discardParkedWorkspace(entry.key.workspace) == true { discardedCount += 1 }
    }
}

// A stateful consumer: the limit is the share of the budget that stays mounted (critical: none), and
// a release slice tears down one workspace (p07-memory-096's sliced release).
extension ParkedWorkspaceBudget: MemoryConsumer {
    package func updateMemoryLimit(_ limit: MemoryLimit) { self.limit = limit }

    /// Tears down one workspace and yields the rest of the slice to the consumers after it: the least
    /// recently parked one that may go of a window off screen, else of a window on screen.
    package func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        let order = liveEntriesLeastRecentFirst()
        let budget = slice.limit.scale(capacity)
        guard order.count > budget else { return .done }
        let releasable = order.filter { !isKept($0) }
        guard let victim = releasable.first(where: { $0.holder?.showsOnScreen == false }) ?? releasable.first else { return .done }
        discard(victim)
        return order.count - 1 > budget && releasable.count > 1 ? .yield : .done
    }

    /// Unknown: a workspace's views are not sampled on their own.
    package var memoryUsage: MemoryUsage? { nil }
}

// The Memory Saver mode scales the idle timeout: a change looks again after this turn, which arms the
// deadline for the new timeout or drops it (off, within the budget).
extension ParkedWorkspaceBudget: MemorySaverModeConsumer {
    package func memorySaverModeDidChange(_ mode: MemorySaverMode) {
        guard mode != saverMode else { return }
        saverMode = mode
        guard !entries.isEmpty else { return }
        deadline.schedule(after: .zero) { [weak self] in self?.plan() }
    }
}
