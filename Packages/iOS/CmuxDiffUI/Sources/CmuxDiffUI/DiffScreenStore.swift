public import CmuxMobileRPC
public import CmuxMobileShell
import Foundation
public import Observation

/// Main-actor state and reducer operations for one live workspace diff screen.
@MainActor
@Observable
public final class DiffScreenStore {
    /// The current summary-level loading state.
    public private(set) var phase: DiffScreenPhase = .idle
    /// The latest decoded summary, when available.
    public private(set) var summary: MobileDiffSummaryResponse?
    /// A typed transient failure displayed above existing content.
    public private(set) var errorBanner: DiffScreenErrorKind?
    /// The persisted layout override used by the screen's overflow menu.
    public var layoutOverride: DiffLayoutOverride {
        didSet { layoutPreferenceStore.save(layoutOverride) }
    }

    @ObservationIgnored private let service: any MobileDiffsServing
    @ObservationIgnored private let viewedStore: DiffViewedStore
    @ObservationIgnored private let layoutPreferenceStore: DiffLayoutPreferenceStore
    private let workspaceRef: String
    private let workspaceID: String
    private let baseSpec: MobileDiffBaseSpec
    private let ignoreWhitespace: Bool
    private(set) var fileStates: [DiffFilePresentationState] = []
    private var loadingPaths: Set<String> = []
    private var generation = 0
    private var retryOperation: RetryOperation = .summary

    /// Creates a live diff store with injected RPC and persistence dependencies.
    /// - Parameters:
    ///   - service: The shell-owned workspace-diffs service seam.
    ///   - workspaceRef: The workspace identifier sent over RPC.
    ///   - workspaceID: Stable device-local identity; defaults to `workspaceRef`.
    ///   - baseSpec: The Git comparison baseline.
    ///   - ignoreWhitespace: Whether Git ignores whitespace-only changes.
    ///   - viewedStore: Device-local per-patch viewed persistence.
    ///   - layoutPreferenceStore: Persistence for manual unified/split selection.
    public init(
        service: any MobileDiffsServing,
        workspaceRef: String,
        workspaceID: String? = nil,
        baseSpec: MobileDiffBaseSpec = MobileDiffBaseSpec(kind: .workingTree),
        ignoreWhitespace: Bool = false,
        viewedStore: DiffViewedStore,
        layoutPreferenceStore: DiffLayoutPreferenceStore
    ) {
        self.service = service
        self.workspaceRef = workspaceRef
        self.workspaceID = workspaceID ?? workspaceRef
        self.baseSpec = baseSpec
        self.ignoreWhitespace = ignoreWhitespace
        self.viewedStore = viewedStore
        self.layoutPreferenceStore = layoutPreferenceStore
        self.layoutOverride = layoutPreferenceStore.load()
    }

    /// Immutable file snapshots currently projected by the store.
    public var files: [DiffFileSnapshot] {
        fileStates.map(\.file)
    }

    /// Collapsed GitHub-style directory roots for the current changed files.
    public var treeNodes: [DiffTreeNode] {
        DiffTreeBuilder().build(files: files)
    }

    /// The number of current patch revisions marked viewed.
    public var viewedCount: Int {
        fileStates.count(where: \.isViewed)
    }

    /// Starts the initial summary request once.
    public func loadInitial() async {
        guard phase == .idle else { return }
        await fetchSummary(isRefresh: false)
    }

    /// Refetches summary metadata while preserving viewed state through persistence.
    public func refresh() async {
        await fetchSummary(isRefresh: true)
    }

    /// Drains every cursor page for one file when it appears or is expanded.
    /// - Parameters:
    ///   - path: The repository-relative file path.
    ///   - force: Whether to bypass the large-diff gate.
    public func loadFile(path: String, force: Bool = false) async {
        guard let index = fileStates.firstIndex(where: { $0.file.summary.path == path }),
              !loadingPaths.contains(path) else { return }
        let current = fileStates[index]
        if !force {
            switch current.file.content {
            case .loaded, .binary, .large, .renameOnly:
                return
            case .loading, .failed:
                break
            }
        }

        loadingPaths.insert(path)
        replaceContent(at: index, with: .loading)
        let requestGeneration = generation
        let file = current.file.summary
        do {
            var hunks: [MobileDiffHunk] = []
            var cursor: Int?
            var seenCursors: Set<Int> = []
            var finalResponse: MobileDiffFileResponse?
            repeat {
                let response = try await service.fileHunks(
                    workspaceRef: workspaceRef,
                    path: file.path,
                    oldPath: file.oldPath,
                    baseSpec: baseSpec,
                    ignoreWhitespace: ignoreWhitespace,
                    cursor: cursor,
                    force: force
                )
                hunks.append(contentsOf: response.hunks)
                finalResponse = response
                cursor = response.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw DiffStoreFailure.repeatedCursor
                }
            } while cursor != nil

            guard requestGeneration == generation,
                  let freshIndex = fileStates.firstIndex(where: { $0.file.summary.path == path }),
                  let finalResponse else { return }
            if finalResponse.isBinary {
                replaceContent(at: freshIndex, with: .binary)
            } else if finalResponse.tooLarge {
                replaceContent(at: freshIndex, with: .large)
            } else {
                replaceContent(at: freshIndex, with: .loaded(hunks))
            }
            errorBanner = nil
        } catch {
            guard requestGeneration == generation,
                  let freshIndex = fileStates.firstIndex(where: { $0.file.summary.path == path }) else { return }
            let kind = errorKind(error)
            replaceContent(at: freshIndex, with: .failed(message(for: kind)))
            showBanner(kind, retry: .file(path: path, force: force))
        }
        loadingPaths.remove(path)
    }

    /// Fetches and splices additional new-side context around a hunk.
    /// - Parameter request: The file, hunk index, and expansion direction.
    public func expandContext(_ request: DiffContextExpansionRequest) async {
        guard let index = fileStates.firstIndex(where: { $0.file.summary.path == request.path }),
              case let .loaded(hunks) = fileStates[index].file.content else { return }
        let splicer = DiffContextSplicer()
        let ranges = splicer.ranges(for: request.direction, hunkIndex: request.hunkIndex, hunks: hunks)
        guard !ranges.isEmpty else { return }
        let requestGeneration = generation
        do {
            var updated = hunks
            for range in ranges {
                let response = try await service.contextRows(
                    workspaceRef: workspaceRef,
                    path: request.path,
                    startLine: range.lowerBound,
                    endLine: range.upperBound,
                    baseSpec: baseSpec,
                    ignoreWhitespace: ignoreWhitespace
                )
                updated = splicer.splice(
                    rows: response.rows,
                    range: range,
                    into: updated,
                    hunkIndex: request.hunkIndex
                )
            }
            guard requestGeneration == generation,
                  let freshIndex = fileStates.firstIndex(where: { $0.file.summary.path == request.path }) else {
                return
            }
            replaceContent(at: freshIndex, with: .loaded(updated))
            errorBanner = nil
        } catch {
            guard requestGeneration == generation else { return }
            showBanner(errorKind(error), retry: .context(request))
        }
    }

    /// Toggles the viewed state for an exact patch digest and persists it.
    /// - Parameter path: The repository-relative file path.
    public func toggleViewed(path: String) {
        guard let index = fileStates.firstIndex(where: { $0.file.summary.path == path }) else { return }
        fileStates[index].isViewed.toggle()
        if fileStates[index].isViewed {
            fileStates[index].isCollapsed = true
        }
        let state = fileStates[index]
        viewedStore.setViewed(
            state.isViewed,
            workspaceID: workspaceID,
            path: state.file.summary.path,
            patchDigest: state.file.summary.patchDigest
        )
    }

    /// Toggles one file section's collapsed state.
    /// - Parameter path: The repository-relative file path.
    public func toggleCollapsed(path: String) {
        guard let index = fileStates.firstIndex(where: { $0.file.summary.path == path }) else { return }
        fileStates[index].isCollapsed.toggle()
    }

    /// Collapses every file section.
    public func collapseAll() {
        for index in fileStates.indices {
            fileStates[index].isCollapsed = true
        }
    }

    /// Retries the operation associated with the current banner.
    public func retryBanner() async {
        switch retryOperation {
        case .summary:
            await refresh()
        case let .file(path, force):
            await loadFile(path: path, force: force)
        case let .context(request):
            await expandContext(request)
        }
    }

    /// Clears a transient error banner without changing loaded content.
    public func dismissBanner() {
        errorBanner = nil
    }

    private func fetchSummary(isRefresh: Bool) async {
        generation += 1
        let requestGeneration = generation
        if summary == nil {
            phase = .loading
        }
        do {
            let response = try await service.summary(
                workspaceRef: workspaceRef,
                baseSpec: baseSpec,
                ignoreWhitespace: ignoreWhitespace
            )
            guard requestGeneration == generation else { return }
            applySummary(response)
            phase = .loaded
            errorBanner = nil
        } catch {
            guard requestGeneration == generation else { return }
            let kind = errorKind(error)
            if summary == nil {
                phase = .failed(kind)
            } else {
                phase = .loaded
                showBanner(kind, retry: .summary)
            }
        }
        if isRefresh {
            loadingPaths.removeAll()
        }
    }

    private func applySummary(_ response: MobileDiffSummaryResponse) {
        let previousCollapse = Dictionary(uniqueKeysWithValues: fileStates.map {
            ($0.file.summary.path, $0.isCollapsed)
        })
        summary = response
        let builder = DiffPresentationBuilder()
        fileStates = response.files.map { summary in
            let content: DiffFileContent
            if summary.isBinary {
                content = .binary
            } else if summary.isLarge {
                content = .large
            } else if (summary.status == .renamed || summary.status == .copied),
                      summary.additions == 0, summary.deletions == 0 {
                content = .renameOnly
            } else {
                content = .loading
            }
            return builder.state(
                file: DiffFileSnapshot(summary: summary, content: content),
                workspaceID: workspaceID,
                viewedStore: viewedStore,
                isCollapsed: previousCollapse[summary.path]
            )
        }
    }

    private func replaceContent(at index: Int, with content: DiffFileContent) {
        let state = fileStates[index]
        var replacement = DiffPresentationBuilder().state(
            file: DiffFileSnapshot(summary: state.file.summary, content: content),
            workspaceID: workspaceID,
            viewedStore: viewedStore,
            isCollapsed: state.isCollapsed
        )
        replacement.isViewed = state.isViewed
        fileStates[index] = replacement
    }

    private func showBanner(_ kind: DiffScreenErrorKind, retry: RetryOperation) {
        errorBanner = kind
        retryOperation = retry
    }

    private func errorKind(_ error: any Error) -> DiffScreenErrorKind {
        guard let serviceError = error as? MobileDiffsServiceError else { return .transport }
        return switch serviceError {
        case .unknownWorkspace: .unknownWorkspace
        case .notGitRepository: .notGitRepository
        case .baselineMissing: .baselineMissing
        }
    }

    private func message(for kind: DiffScreenErrorKind) -> String {
        let localized = DiffLocalized()
        return switch kind {
        case .unknownWorkspace:
            localized.string("diff.error.workspace.message", defaultValue: "This workspace is no longer available on the paired computer.")
        case .notGitRepository:
            localized.string("diff.error.repository.message", defaultValue: "This workspace is not a Git repository.")
        case .baselineMissing:
            localized.string("diff.error.baseline.message", defaultValue: "The selected comparison baseline is no longer available.")
        case .transport:
            localized.string("diff.error.transport.message", defaultValue: "The diff could not be loaded from the paired computer.")
        }
    }

    private enum RetryOperation {
        case summary
        case file(path: String, force: Bool)
        case context(DiffContextExpansionRequest)
    }
}
