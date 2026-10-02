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
    /// Why the folder could not be prepared, if it could not.
    public private(set) var failure: String?
    public let folder: FirstTaskFolder
    @ObservationIgnored private let services: any OnboardingServices
    @ObservationIgnored private var watch: FolderWatch?

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
        failure = nil
        let folder = folder
        // task-owner: one-shot folder setup (a directory and a small file)
        Task { [weak self] in
            let error = await Task.detached { () -> String? in
                do { try folder.prepare(for: value); return nil } catch { return String(describing: error) }
            }.value
            guard let self else { return }
            isPreparing = false
            if let error { failure = error; return }
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
        // task-owner: one-shot directory listing off the main thread
        Task { [weak self] in
            let files = await Task.detached { folder.outputs() }.value
            self?.outputs = files
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
