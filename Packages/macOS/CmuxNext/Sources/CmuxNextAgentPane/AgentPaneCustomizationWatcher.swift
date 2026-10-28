import CmuxNextSettings
public import CmuxNextWakeups
public import Foundation

/// Watches the agent pane customization files (`theme.css`, `layout.json`,
/// `registry.js` in the `agent-pane` directory next to `cmux.json`) and
/// reports each change on the main actor. Every save style (in place, atomic
/// rename, delete and recreate, the directory appearing later) counts; the
/// files are read off the main actor and an unchanged result is dropped.
///
/// A file event and each read's result reach the main actor as `visible` tasks on the app's
/// scheduler (the person edited a file outside the app; every open chat shows it): Chromium's
/// `PostTaskAndReplyWithResult` onto a typed UI task runner (base/task/task_runner_util.h). At most
/// one read runs; events during it make one more read after it.
public final class AgentPaneCustomizationWatcher {
    /// The latest files read, empty until the first read completes.
    public private(set) var current = AgentPaneCustomization()
    /// Called on the main actor with each new value.
    public var onChange: ((AgentPaneCustomization) -> Void)?

    private let directory: URL
    private let mainWork: MainWorkScheduler
    /// The owner of the event hops and the reads' results, interned once.
    private let owner: MainTaskOwner
    private var watchers: [ConfigFileWatcher] = []
    /// The read off the main actor; at most one runs.
    private var reading: Task<Void, Never>?
    /// Bumped by ``stop()``: a read's result of an older watch is dropped.
    private var generation: UInt64 = 0
    private var reloadRequested = false

    /// - Parameters:
    ///   - directory: The `agent-pane` directory next to `cmux.json`.
    ///   - mainWork: The app's main-thread scheduler: the events and the reads' results land on it.
    public init(directory: URL, mainWork: MainWorkScheduler) {
        self.directory = directory
        self.mainWork = mainWork
        owner = mainWork.board.owner("AgentPaneCustomizationWatcher")
    }

    /// Arms the watch and reads the files once. Does nothing while running.
    public func start() {
        guard watchers.isEmpty else { return }
        let mainWork = mainWork, owner = owner
        watchers = AgentPaneCustomization.fileNames.map { name in
            ConfigFileWatcher(url: directory.appending(path: name)) { [weak self] in
                mainWork.postFromAnyThread(.visible, owner: owner) { self?.requestReload() }
            }
        }
        for watcher in watchers { watcher.start() }
    }

    /// Stops watching; ``current`` keeps the last value read.
    public func stop() {
        for watcher in watchers { watcher.stop() }
        watchers = []
        generation &+= 1
        reading?.cancel()
        reading = nil
        reloadRequested = false
    }

    private func requestReload() {
        guard !watchers.isEmpty else { return }
        reloadRequested = true
        readIfIdle()
    }

    /// Starts the read of a pending reload when none runs: the files are read off the main actor, and the
    /// result lands as one `visible` task.
    private func readIfIdle() {
        guard reading == nil, reloadRequested else { return }
        reloadRequested = false
        let directory = directory, mainWork = mainWork, owner = owner, generation = generation
        let land: @MainActor @Sendable (AgentPaneCustomization) -> Void = { [weak self] value in
            self?.landed(value, generation: generation)
        }
        // task-owner: one read of the customization files, off main; stop() cancels it and drops its result
        reading = Task { @concurrent in
            let value = AgentPaneCustomization(directory: directory)
            guard !Task.isCancelled else { return }
            mainWork.postFromAnyThread(.visible, owner: owner) { land(value) }
        }
    }

    /// A read's result on the main actor: applied, then the reload asked for meanwhile, if any.
    private func landed(_ value: AgentPaneCustomization, generation: UInt64) {
        guard generation == self.generation else { return }
        reading = nil
        apply(value)
        readIfIdle()
    }

    private func apply(_ value: AgentPaneCustomization) {
        guard value != current else { return }
        current = value
        onChange?(value)
    }

    /// Saves the chat header's quick actions into `layout.json` (its right-click menu); the watch
    /// then pushes the file to every chat. Returns whether it was written.
    public func saveQuickActions(_ list: [AgentPaneQuickAction]) async -> Bool {
        let saved = await Self.write(list, in: directory)
        if saved { requestReload() }
        return saved
    }

    @concurrent private static func write(_ list: [AgentPaneQuickAction], in directory: URL) async -> Bool {
        (try? AgentPaneCustomization.savingQuickActions(list, in: directory)) != nil
    }
}
