package import CmuxNextCompat
package import CmuxNextWakeups

/// A window that keeps hidden workspaces mounted and paused (the App's `WindowController`).
@MainActor
package protocol ParkedWorkspaceHolder: AnyObject {
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
///   limit (critical: none). Past it the least recently parked one that may go is torn down, as
///   Chrome's `FrameEvictionManager` culls the oldest unlocked saved frame
///   (components/viz/client/frame_eviction_manager.cc, `CullUnlockedFrames`): one its holder keeps
///   (a `sidebar.multiView` companion on screen, the workspace under a top page) still counts.
/// - **Idle timeout.** A parked workspace hidden ``idleTimeout`` goes even within the budget, as
///   Chrome's proactive discard takes tabs hidden past their time
///   (chrome/browser/resource_coordinator/tab_lifecycle_unit.cc).
/// - **Pressure.** A ``MemoryConsumer`` of the app's coordinator: a lower limit is released by
///   ``releaseMemory(within:)``, one teardown per slice.
///
/// Events only: parks, shows and closes, and one ``ParkedWorkspaceDeadline`` for the next look.
/// Each look (``plan()``) tears down at most one workspace, after the switch's turn, never in it,
/// and asks for the next look on a later task while more are due (p07-memory.md rule 2).
@MainActor
package final class ParkedWorkspaceBudget {
    /// How the budget lists a consumer for the coordinator: a workspace view tree is large, costly
    /// to mount again, and loses its view-only state.
    package static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .none, retention: .lossy, recreateCost: .expensive,
        releaseCPUCost: .high, isStateful: true, supportsMemoryLimit: true)

    /// Parked workspaces across all windows at normal pressure (`SubsystemBudget.parkedWorkspaces`).
    package let capacity: Int
    /// How long a parked workspace may stay hidden; nil: only the budget and pressure tear down.
    package let idleTimeout: Duration?
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
        /// When it was parked, or last seen kept (a kept workspace is in use).
        var since: ContinuousClock.Instant
        /// Least recently parked first.
        var serial: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var serial: UInt64 = 0
    private let deadline: any ParkedWorkspaceDeadline
    private let now: () -> ContinuousClock.Instant
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - capacity: Parked workspaces across all windows at normal pressure.
    ///   - idleTimeout: How long one may stay hidden; nil for no timeout.
    ///   - deadline: The one deadline of the next look.
    ///   - memory: The app's memory coordinator; nil keeps the limit at 100 %.
    ///   - now: The clock of hidden times (tests set it).
    package init(capacity: Int, idleTimeout: Duration?, deadline: any ParkedWorkspaceDeadline,
                 memory: (any MemoryConsumerRegistry)? = nil, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.capacity = max(capacity, 0)
        self.idleTimeout = idleTimeout
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
        entries[key] = Entry(holder: holder, key: key, since: now(), serial: serial)
        deadline.schedule(after: .zero) { [weak self] in self?.plan() }
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
    /// else the longest hidden one past the idle timeout, and arms the next look. A workspace its
    /// holder keeps is in use: it becomes the most recently parked and its hidden time starts again.
    package func plan() {
        let at = now()
        var kept: Set<Key> = []
        for entry in liveEntriesLeastRecentFirst() where isKept(entry) {
            kept.insert(entry.key)
            serial &+= 1
            entries[entry.key]?.serial = serial
            entries[entry.key]?.since = at
        }
        let order = entries.values.sorted { $0.serial < $1.serial }
        // Least recently parked first, so this is also the one hidden longest.
        let oldest = order.first { !kept.contains($0.key) }
        if order.count > currentCapacity, let oldest { return discardAndLookAgain(oldest) }
        guard let idleTimeout else { return deadline.cancel() }
        // A kept one is looked at again a timeout later: no event says it stopped being kept.
        var wait: Duration? = kept.isEmpty ? nil : idleTimeout
        if let oldest {
            let remaining = idleTimeout - (at - oldest.since)
            if remaining <= .zero { return discardAndLookAgain(oldest) }
            wait = min(wait ?? remaining, remaining)
        }
        if let wait {
            deadline.schedule(after: wait) { [weak self] in self?.plan() }
        } else {
            deadline.cancel()
        }
    }

    /// One teardown per look; the next look runs on a later task.
    private func discardAndLookAgain(_ entry: Entry) {
        discard(entry)
        deadline.schedule(after: .zero) { [weak self] in self?.plan() }
    }

    /// The live entries, least recently parked first; entries of closed holders go.
    private func liveEntriesLeastRecentFirst() -> [Entry] {
        entries = entries.filter { $0.value.holder != nil }
        return entries.values.sorted { $0.serial < $1.serial }
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

    package func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        let order = liveEntriesLeastRecentFirst()
        let budget = slice.limit.scale(capacity)
        guard order.count > budget, let victim = order.first(where: { !isKept($0) }) else { return .done }
        discard(victim)
        let more = order.count - 1 > budget && order.contains { $0.key != victim.key && !isKept($0) }
        return more ? .more : .done
    }

    /// Unknown: a workspace's views are not sampled on their own.
    package var memoryUsage: MemoryUsage? { nil }
}
