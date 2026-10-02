public import Foundation
public import Observation

/// First task: two cards; picking one prepares the first-task folder and
/// starts a real agent chat there with the task's prompt. Files the task
/// saves appear as they land. Leaving the step leaves the chat running.
@MainActor
@Observable
public final class FirstTaskStepModel {
    /// The picked task; set once its folder is ready, so the chat starts in it.
    public private(set) var task: FirstTask?
    /// Set while the folder is being prepared.
    public private(set) var isPreparing = false
    /// The task's saved files, newest first.
    public private(set) var outputs: [URL] = []
    /// True when the folder could not be prepared (the step says so; Skip stays).
    public private(set) var failed = false
    public let folder: FirstTaskFolder
    @ObservationIgnored private let services: any OnboardingServices
    @ObservationIgnored private var watch: FolderWatch?
    /// When the task was picked: files older than this are from an earlier run.
    @ObservationIgnored private var startedAt = Date.distantPast
    /// Bumped per listing, so a slow older listing never replaces a newer one.
    @ObservationIgnored private var listing = 0

    init(services: any OnboardingServices) {
        self.services = services
        folder = services.firstTaskFolder
    }

    /// The prompt the chat starts with.
    public var prompt: String? { task.map(OnboardingStrings.firstTaskPrompt) }

    /// Picks a task (once): prepares the folder off the main thread, then
    /// the step shows the chat.
    public func pick(_ value: FirstTask) {
        guard task == nil, !isPreparing else { return }
        isPreparing = true
        failed = false
        // A second's slack for file systems that round modification times.
        startedAt = Date().addingTimeInterval(-1)
        let folder = folder
        // task-owner: one-shot folder setup (a directory and a small file)
        Task { [weak self] in
            let prepared = await Task.detached { (try? folder.prepare(for: value)) != nil }.value
            guard let self else { return }
            isPreparing = false
            guard prepared else { failed = true; return }
            task = value
            startWatching()
        }
    }

    public func open(_ file: URL) { services.openExternal(file) }
    public func reveal(_ file: URL) { services.revealInFinder(file) }

    /// Re-reads the folder (also when a file lands).
    public func refreshOutputs() {
        guard task != nil else { return }
        let folder = folder
        let since = startedAt
        listing += 1
        let current = listing
        // task-owner: one-shot directory listing off the main thread
        Task { [weak self] in
            let files = await Task.detached { folder.outputs(since: since) }.value
            guard let self, current == listing else { return }
            outputs = files
        }
    }

    private func startWatching() {
        watch = FolderWatch(folder.url) { [weak self] in self?.refreshOutputs() }
        refreshOutputs()
    }

    /// Onboarding ended: stop watching the folder.
    func stop() {
        watch?.cancel()
        watch = nil
    }
}
