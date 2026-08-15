import CmuxGit
import CmuxSidebarGit
import Foundation
import Observation

/// The changed-file + per-file-diff surface the git diff panel renders from.
///
/// A seam so tests can inject a controllable fake instead of driving real Git.
/// ``WorkspaceChangesService`` conforms below; the panel depends on this
/// protocol, never the concrete service.
protocol GitDiffWorkspaceChangesServing: Sendable {
    /// Reads the changed-file listing for `directory`.
    func changedFiles(forDirectory directory: String, force: Bool) async throws -> WorkspaceChangedFiles
    /// Reads a bounded unified diff for `path` inside `directory`.
    func fileDiff(
        forDirectory directory: String,
        path: String,
        maxLines: Int?
    ) async throws -> WorkspaceFileDiff
}

extension WorkspaceChangesService: GitDiffWorkspaceChangesServing {}

/// An immutable snapshot of the git diff panel's loaded content.
///
/// Value type deliberately: it crosses the ``GitDiffPanelView`` `LazyVStack` /
/// `ForEach` boundary, so no observable store reference may ride along.
struct GitDiffPanelSnapshot: Equatable {
    let files: WorkspaceChangedFiles
    let selectedPath: String?
    let selectedDiff: WorkspaceFileDiff?
    let diffRows: [GitDiffRow]
}

/// Drives the git diff right-sidebar panel.
///
/// All git and diff-parsing work runs off the main actor (the injected
/// ``GitDiffWorkspaceChangesServing`` is `nonisolated async`, and diff rows are
/// parsed in a detached task). The main actor only observes compact immutable
/// ``GitDiffPanelSnapshot`` values.
@MainActor
@Observable
final class GitDiffPanelViewModel {
    enum State: Equatable {
        case loading
        case unavailable(String)
        case error(String, retry: Bool)
        case loaded(GitDiffPanelSnapshot)
    }

    private(set) var state: State = .loading

    /// Whether the enclosing right sidebar is currently visible.
    ///
    /// Refresh work is gated on this: while hidden the panel stays mounted but
    /// does not load or parse. The view sets it on appear / visibility change.
    var isVisible: Bool = false

    private let changesService: any GitDiffWorkspaceChangesServing
    private let invalidationStreamFactory: () -> AsyncStream<WorkspaceGitInvalidationEvent>

    private var directory: String?
    private var selectedPath: String?
    private var currentFiles: WorkspaceChangedFiles?
    private var refreshGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var subscriptionTask: Task<Void, Never>?

    /// Creates the view model.
    ///
    /// - Parameters:
    ///   - changesService: Loads changed files and per-file diffs.
    ///   - invalidationStreamFactory: Produces the directory-keyed git
    ///     invalidation stream to consume for live refreshes.
    init(
        changesService: any GitDiffWorkspaceChangesServing = WorkspaceChangesService(),
        invalidationStreamFactory: @escaping () -> AsyncStream<WorkspaceGitInvalidationEvent> =
            { AsyncStream { _ in } }
    ) {
        self.changesService = changesService
        self.invalidationStreamFactory = invalidationStreamFactory
    }

    /// Starts observing git invalidations once; safe to call repeatedly.
    ///
    /// Idempotent: a running subscription is left in place. Call from the
    /// view's `onAppear` so the subscription's lifecycle follows the panel.
    func startObservingInvalidations() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { @MainActor [weak self] in
            for await event in self?.invalidationStreamFactory() ?? AsyncStream { _ in } {
                guard let self, self.isVisible else { continue }
                guard let directory = self.directory, event.directory == directory else { continue }
                self.refresh()
            }
        }
    }

    /// Re-resolves and (re)loads content for `directory`.
    ///
    /// A `nil` directory (non-repo / remote / no workspace) shows the
    /// unavailable state. A non-visible panel stores the directory but defers
    /// loading until it becomes visible. A new call cancels any in-flight
    /// refresh and bumps the generation so a stale result is discarded.
    ///
    /// - Parameters:
    ///   - directory: The effective local working directory, or `nil`.
    ///   - force: Whether to bypass the service's loaded-snapshot cache.
    func setDirectory(_ directory: String?, force: Bool = false) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if directory != self.directory {
            selectedPath = nil
        }
        self.directory = directory

        refreshTask?.cancel()
        refreshTask = nil

        guard let directory else {
            state = .unavailable(Self.unavailableMessage)
            return
        }
        guard isVisible else { return }

        refreshTask = Task { @MainActor in
            await refreshFiles(directory: directory, generation: generation, force: force)
        }
    }

    /// Selects a changed file and loads its inline diff.
    ///
    /// - Parameter path: A repository-relative path from the loaded listing.
    func selectFile(_ path: String) {
        selectedPath = path
        guard isVisible, directory != nil else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            await refreshDiff(path: path, directory: directory, generation: generation)
        }
    }

    /// Manually refreshes the current directory, bypassing the cache.
    func refresh() {
        setDirectory(directory, force: true)
    }

    /// Cancels the in-flight refresh and the invalidation subscription.
    ///
    /// Called only on true unmount (`onDisappear`, e.g. mode switch). Hiding
    /// the sidebar keeps the subscription alive (gated on `isVisible`) so a
    /// re-show resumes without restarting the stream.
    func cancelInFlight() {
        refreshTask?.cancel()
        refreshTask = nil
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    private func refreshFiles(directory: String, generation: UInt64, force: Bool) async {
        do {
            let files = try await changesService.changedFiles(forDirectory: directory, force: force)
            guard generation == refreshGeneration else { return }
            guard files.isRepository else {
                state = .unavailable(Self.notARepositoryMessage)
                return
            }
            currentFiles = files
            let snapshot = GitDiffPanelSnapshot(
                files: files,
                selectedPath: nil,
                selectedDiff: nil,
                diffRows: []
            )
            state = .loaded(snapshot)
            if let selectedPath, files.files.contains(where: { $0.path == selectedPath }) {
                await refreshDiff(path: selectedPath, directory: directory, generation: generation)
            }
        } catch {
            guard generation == refreshGeneration else { return }
            state = .error(Self.loadErrorMessage, retry: true)
        }
    }

    private func refreshDiff(path: String, directory: String?, generation: UInt64) async {
        guard let directory, let currentFiles else { return }
        guard let file = currentFiles.files.first(where: { $0.path == path }) else { return }
        do {
            let diff = try await changesService.fileDiff(forDirectory: directory, path: path, maxLines: nil)
            guard generation == refreshGeneration else { return }
            // Parse the potentially large unified diff off the main actor.
            let rows = await Task.detached(priority: .userInitiated) {
                GitDiffParser.parse(diff.unifiedDiff)
            }.value
            guard generation == refreshGeneration else { return }
            let snapshot = GitDiffPanelSnapshot(
                files: currentFiles,
                selectedPath: path,
                selectedDiff: diff,
                diffRows: rows
            )
            state = .loaded(snapshot)
        } catch {
            guard generation == refreshGeneration else { return }
            state = .error(Self.loadErrorMessage, retry: true)
        }
    }

    private static let notARepositoryMessage = String(
        localized: "gitDiff.panel.notARepository",
        defaultValue: "Not a git repository"
    )
    private static let unavailableMessage = String(
        localized: "gitDiff.panel.unavailable",
        defaultValue: "Git unavailable on this workspace"
    )
    private static let loadErrorMessage = String(
        localized: "gitDiff.panel.loadError",
        defaultValue: "Couldn't load git changes"
    )
}
