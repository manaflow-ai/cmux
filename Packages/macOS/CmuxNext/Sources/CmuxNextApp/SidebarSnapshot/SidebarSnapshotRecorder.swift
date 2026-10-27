import CmuxNextSidebar
import CmuxNextWakeups

/// Saves one window's sidebar to `SidebarSnapshotStore` (SidebarBridge):
/// only what changed since the last save, in order.
///
/// A sidebar pass only marks the sidebar changed. The snapshot of every row is built in an idle
/// task (`MainWorkScheduler.postIdle`) from what the sidebar shows when it runs, so a burst of
/// passes builds one snapshot and none is built in a person's input response; the store (an
/// actor) merges it and writes the file off the main thread. This is Chrome's session save: a
/// change only schedules the save, which runs later with the newest state
/// (`components/sessions/core/command_storage_manager.cc`, `ScheduleSave`, `kSaveDelayMS`). Quit
/// does not wait for the task: ``flushNow(_:window:services:)`` builds the queued snapshot at once,
/// before the store's own flush, as Chrome's session service writes its pending commands at once
/// when the browser shuts down (`CommandStorageManager::Save`), not at its next timer. A closed
/// window needs no flush: the store forgets it (`WindowManager.userClosed`).
final class SidebarSnapshotRecorder {
    /// The longest a changed sidebar waits for idle time before its snapshot is built as
    /// background work (Chrome's session save delay, `kSaveDelayMS`, is 2.5 s).
    static let maxDelay: Duration = .milliseconds(2500)

    /// What a record checks, where it saves and where it posts its idle task.
    struct Target {
        /// Whether a window is incognito (never saved).
        var isIncognito: @MainActor (String) -> Bool
        /// Whether a window's sidebar is saved now: an open registered window, after the launch.
        var isSavable: @MainActor (String) -> Bool
        /// Hands a window's snapshot, with its sequence, to the store.
        var save: @MainActor (SidebarSnapshot, String, UInt64) -> Void
        /// Queues a body for the main thread's idle time, never inline; past the delay it runs as
        /// background work.
        var postIdle: @MainActor (String, Duration, @escaping @MainActor () -> Void) -> Void
    }

    /// The rows' content revision and space bar last saved (a pass that moved neither builds no snapshot of every row),
    /// and the order of saves.
    private var savedKey: (UInt64, [SidebarProfile], ProfileKey?)?
    private var recordSequence: UInt64 = 0
    /// Once incognito, never saved, even after the window leaves the
    /// incognito set on its way out.
    private var everIncognito = false
    /// An idle task is queued: later passes leave it to save the newest state.
    private(set) var isQueued = false
    /// Bumped by each post and each flush: an idle task of an older post saves nothing.
    private var generation: UInt64 = 0

    /// `model` changed: what it shows (placeholders and live-only detail left out) is saved in an
    /// idle task, once the launch is over, only for an open registered window and never an
    /// incognito one (a closing incognito window leaves the incognito set before its sidebar goes
    /// away).
    func record(_ model: SidebarModel, window: String, services: AppServices) {
        record(model, window: window, target: Self.target(services))
    }

    /// ``record(_:window:services:)`` against `target` (tests pass their own).
    func record(_ model: SidebarModel, window: String, target: Target) {
        guard !isQueued, needsSave(model, window: window, target: target) else { return }
        isQueued = true
        generation &+= 1
        let posted = generation
        target.postIdle("SidebarSnapshot.record", Self.maxDelay) { [weak self, weak model] in
            guard let self, self.isQueued, self.generation == posted else { return }
            self.isQueued = false
            guard let model, let save = self.take(model, window: window, target: target) else { return }
            target.save(save.snapshot, window, save.sequence)
        }
    }

    /// The queued idle task's save, now (quit): the snapshot of what `model` shows, with its
    /// sequence, when a change still waits for its task. The caller awaits the store's record of it
    /// before the store's flush; the queued task then saves nothing.
    func flushNow(_ model: SidebarModel, window: String, services: AppServices) -> (snapshot: SidebarSnapshot, sequence: UInt64)? {
        flushNow(model, window: window, target: Self.target(services))
    }

    /// ``flushNow(_:window:services:)`` against `target` (tests pass their own).
    func flushNow(_ model: SidebarModel, window: String, target: Target) -> (snapshot: SidebarSnapshot, sequence: UInt64)? {
        guard isQueued else { return nil }
        isQueued = false
        generation &+= 1
        return take(model, window: window, target: target)
    }

    /// Whether `model` shows what was not saved yet, for a window whose sidebar is saved now.
    private func needsSave(_ model: SidebarModel, window: String, target: Target) -> Bool {
        if target.isIncognito(window) { everIncognito = true }
        guard !everIncognito, target.isSavable(window) else { return false }
        guard let key = savedKey else { return true }
        return !(key.0 == model.contentRevision && key.1 == model.profiles && key.2 == model.activeProfileID)
    }

    /// The checks again (the window may have closed or gone incognito since the pass), then the
    /// snapshot of what the sidebar shows now, with the next sequence.
    private func take(_ model: SidebarModel, window: String, target: Target) -> (snapshot: SidebarSnapshot, sequence: UInt64)? {
        guard needsSave(model, window: window, target: target) else { return nil }
        savedKey = (model.contentRevision, model.profiles, model.activeProfileID)
        recordSequence += 1
        return (SidebarSnapshot(sections: model.sections, profiles: model.profiles, activeProfileID: model.activeProfileID), recordSequence)
    }

    /// The app's target: its window registry, its snapshot store (merged and written off main, on
    /// a background task quit waits for) and its main-thread scheduler's idle class.
    private static func target(_ services: AppServices) -> Target {
        Target(isIncognito: { [weak services] window in services?.windows.registry.value.isIncognito(window) ?? false },
               isSavable: { [weak services] window in
                   guard let registry = services?.windows.registry else { return false }
                   return !registry.isLaunching && registry.value.window(window)?.isOpen == true
               },
               save: { [weak services] snapshot, window, sequence in
                   guard let services else { return }
                   let store = services.sidebarSnapshots
                   // Sendable, so not main-actor: the hop goes straight to the store's actor.
                   services.work.task(.userVisible, shutdown: .blockShutdown) { @Sendable in
                       await store.record(snapshot, window: window, sequence: sequence)
                   }
               },
               postIdle: { [weak services] owner, maxDelay, body in
                   services?.mainWork.postIdle(owner: owner, maxDelay: maxDelay) { _ in body() }
               })
    }
}
