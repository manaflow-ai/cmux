internal import CmuxMobileRPC
internal import Foundation
internal import Observation

#if canImport(UIKit)
internal import UIKit
#endif

/// Main-actor coordinator for live native diff loading and immutable list projections.
@MainActor @Observable
final class ChangesViewModel {
    private let service: any MobileChangesLoading
    private let workspace: ChangesWorkspaceContext
    private let baseSpec: MobileChangesBaseSpec
    private let rowBuilder: DiffRowBuilder
    private let splicer: ContextRowSplicer
    private let languageInference: CodeLanguageInference
    private let highlighting: SyntaxHighlightingPipeline
    private var viewedStore: ViewedStateStore
    private var summary: MobileChangesSummaryResponse?
    private var fileStates: [String: DiffFileState] = [:]
    private var highlightTasks: [String: Task<Void, Never>] = [:]
    private var highlightScheme: DiffHighlightScheme = .light
    private(set) var isLoadingSummary = false
    private(set) var ignoresWhitespace = false
    private(set) var error: ChangesErrorSnapshot?

    /// Creates a live changes coordinator.
    /// - Parameters:
    ///   - service: Workspace-bound changes service or preview fixture.
    ///   - workspace: Workspace identity used by local viewed state.
    ///   - baseSpec: Git baseline request, defaulting to the working tree.
    ///   - defaults: Injected device-local persistence.
    ///   - highlighting: Actor-isolated syntax pipeline.
    init(
        service: any MobileChangesLoading,
        workspace: ChangesWorkspaceContext,
        baseSpec: MobileChangesBaseSpec = MobileChangesBaseSpec(kind: .workingTree),
        defaults: UserDefaults = .standard,
        highlighting: SyntaxHighlightingPipeline = SyntaxHighlightingPipeline()
    ) {
        self.service = service
        self.workspace = workspace
        self.baseSpec = baseSpec
        rowBuilder = DiffRowBuilder()
        splicer = ContextRowSplicer()
        languageInference = CodeLanguageInference()
        viewedStore = ViewedStateStore(defaults: defaults)
        self.highlighting = highlighting
    }

    /// Current immutable list projection.
    var snapshot: ChangesScreenSnapshot {
        let files = summary?.files.compactMap { fileStates[$0.path]?.snapshot } ?? []
        return ChangesScreenSnapshot(
            isLoadingSummary: isLoadingSummary,
            error: error,
            totals: summary?.totals,
            files: files,
            viewedCount: files.lazy.filter(\.isViewed).count,
            ignoresWhitespace: ignoresWhitespace
        )
    }

    /// Closure-only actions safe to pass below a lazy list boundary.
    var actions: ChangesScreenActions {
        ChangesScreenActions(
            retrySummary: { [weak self] in self?.startLoad() },
            toggleWhitespace: { [weak self] in self?.toggleWhitespace() },
            collapseAll: { [weak self] in self?.setAllCollapsed(true) },
            expandAll: { [weak self] in self?.setAllCollapsed(false) },
            toggleFile: { [weak self] in self?.toggleFile(path: $0) },
            toggleViewed: { [weak self] in self?.toggleViewed(path: $0) },
            loadFile: { [weak self] in self?.startFileLoad(path: $0) },
            copyPath: { [weak self] in self?.copyPath($0) },
            expandGap: { [weak self] path, gap, direction in
                self?.startGapExpansion(path: path, gapID: gap, direction: direction)
            }
        )
    }

    /// Loads the summary and ordinary file diffs.
    func load() async {
        cancelHighlighting()
        isLoadingSummary = true
        error = nil
        summary = nil
        fileStates = [:]
        do {
            let response = try await service.summary(baseSpec: baseSpec, ignoreWhitespace: ignoresWhitespace)
            try Task.checkCancellation()
            summary = response
            for file in response.files {
                let key = ViewedFileKey(workspaceID: workspace.workspaceID, path: file.path, patchDigest: file.patchDigest)
                fileStates[file.path] = initialState(file: file, isViewed: viewedStore.isViewed(key))
            }
            isLoadingSummary = false
            for file in response.files where !file.isBinary && !file.isLarge {
                try Task.checkCancellation()
                await loadFile(path: file.path)
            }
        } catch is CancellationError {
            isLoadingSummary = false
        } catch {
            isLoadingSummary = false
            self.error = errorSnapshot(error)
        }
    }

    /// Updates highlighting appearance and re-highlights loaded source rows.
    /// - Parameter scheme: Active light or dark syntax theme.
    func setHighlightScheme(_ scheme: DiffHighlightScheme) {
        guard highlightScheme != scheme else { return }
        highlightScheme = scheme
        for path in fileStates.keys { startHighlighting(path: path) }
    }

    /// Cancels lifecycle-bound asynchronous highlighting work.
    func cancelTransientWork() {
        cancelHighlighting()
    }

    private func startLoad() {
        Task { await load() }
    }

    private func initialState(file: MobileChangesFile, isViewed: Bool) -> DiffFileState {
        let rows: [DiffRowSnapshot]
        if file.isBinary {
            rows = [DiffRowSnapshot(id: "binary:\(file.path)", kind: .binary, text: "")]
        } else if file.isLarge {
            rows = [DiffRowSnapshot(id: "large:\(file.path)", kind: .largeDiff, text: "")]
        } else {
            rows = [DiffRowSnapshot(id: "loading:\(file.path)", kind: .loading, text: "")]
        }
        return DiffFileState(
            file: file,
            hunks: [],
            rows: rows,
            isCollapsed: file.isLarge || isViewed,
            isViewed: isViewed,
            isLoading: !file.isBinary && !file.isLarge,
            loadedPageCount: 0,
            errorMessage: nil
        )
    }

    private func startFileLoad(path: String) {
        Task { await loadFile(path: path) }
    }

    private func loadFile(path: String) async {
        guard var state = fileStates[path], !state.file.isBinary else { return }
        state.isLoading = true
        state.isCollapsed = false
        state.errorMessage = nil
        if state.hunks.isEmpty, state.file.isLarge {
            state.rows = [DiffRowSnapshot(id: "large:\(path)", kind: .largeDiff, text: "")]
        } else if state.hunks.isEmpty {
            state.rows = [DiffRowSnapshot(id: "loading:\(path)", kind: .loading, text: "")]
        }
        fileStates[path] = state
        do {
            var hunks: [MobileChangesHunk] = []
            var cursor: String?
            var seenCursors: Set<String> = []
            var pages = 0
            var exceededAbsoluteLimit = false
            repeat {
                let page = try await service.fileDiff(
                    path: state.file.path,
                    oldPath: state.file.oldPath,
                    cursor: cursor,
                    ignoreWhitespace: ignoresWhitespace,
                    baseSpec: baseSpec
                )
                try Task.checkCancellation()
                hunks.append(contentsOf: page.hunks)
                exceededAbsoluteLimit = exceededAbsoluteLimit || page.tooLarge
                pages += 1
                cursor = page.nextCursor
                if let nextCursor = cursor, !seenCursors.insert(nextCursor).inserted { cursor = nil }
                if var progress = fileStates[path] {
                    progress.loadedPageCount = pages
                    fileStates[path] = progress
                }
            } while cursor != nil
            guard var loaded = fileStates[path] else { return }
            loaded.hunks = hunks
            if exceededAbsoluteLimit, hunks.isEmpty {
                loaded.rows = [DiffRowSnapshot(id: "too-large:\(path)", kind: .tooLarge, text: "")]
            } else if hunks.isEmpty, loaded.file.status == .renamed || loaded.file.status == .copied {
                loaded.rows = [DiffRowSnapshot(id: "rename:\(path)", kind: .renameOnly, text: "")]
            } else {
                loaded.rows = rowBuilder.rows(
                    file: loaded.file,
                    hunks: hunks,
                    includeEOFGap: loaded.file.status != .deleted
                )
            }
            loaded.isLoading = false
            loaded.loadedPageCount = pages
            fileStates[path] = loaded
            startHighlighting(path: path)
        } catch is CancellationError {
            if var cancelled = fileStates[path] {
                cancelled.isLoading = false
                fileStates[path] = cancelled
            }
        } catch {
            if var failed = fileStates[path] {
                failed.isLoading = false
                failed.errorMessage = String(localized: "diff.error.file", defaultValue: "Couldn’t load this file. Try again.", bundle: .module)
                failed.rows = [DiffRowSnapshot(id: "error:\(path)", kind: .error, text: "")]
                fileStates[path] = failed
            }
        }
    }

    private func startGapExpansion(path: String, gapID: String, direction: ContextExpansionDirection) {
        Task { await expandGap(path: path, gapID: gapID, direction: direction) }
    }

    private func expandGap(path: String, gapID: String, direction: ContextExpansionDirection) async {
        guard let state = fileStates[path],
              let gap = state.rows.first(where: { $0.expansionGap?.id == gapID })?.expansionGap,
              let plan = ContextExpansionPlan(gap: gap, direction: direction) else { return }
        do {
            let response = try await service.contextLines(
                path: path,
                start: plan.requestedRange.lowerBound,
                end: plan.requestedRange.upperBound,
                baseSpec: baseSpec
            )
            try Task.checkCancellation()
            guard var current = fileStates[path] else { return }
            current.rows = splicer.splice(rows: current.rows, gapID: gapID, plan: plan, texts: response.rows)
            fileStates[path] = current
            startHighlighting(path: path)
        } catch {
            guard var current = fileStates[path] else { return }
            current.errorMessage = String(localized: "diff.error.context", defaultValue: "Couldn’t expand context. Try again.", bundle: .module)
            current.rows.append(DiffRowSnapshot(id: "context-error:\(gapID)", kind: .error, text: ""))
            fileStates[path] = current
        }
    }

    private func startHighlighting(path: String) {
        highlightTasks[path]?.cancel()
        highlightTasks[path] = Task { [weak self] in await self?.highlight(path: path) }
    }

    private func highlight(path: String) async {
        guard let state = fileStates[path], let language = languageInference.language(for: path) else { return }
        let requests = state.rows.compactMap { row -> DiffHighlightRequest? in
            switch row.kind {
            case .context, .addition, .deletion:
                DiffHighlightRequest(rowID: row.id, text: row.text, language: language)
            default:
                nil
            }
        }
        do {
            let highlighted = try await highlighting.highlights(for: requests, scheme: highlightScheme)
            try Task.checkCancellation()
            guard var current = fileStates[path] else { return }
            current.rows = current.rows.map { row in
                var row = row
                row.highlightedText = highlighted[row.id]
                return row
            }
            fileStates[path] = current
        } catch {}
    }

    private func toggleWhitespace() {
        ignoresWhitespace.toggle()
        startLoad()
    }

    private func setAllCollapsed(_ collapsed: Bool) {
        for path in fileStates.keys {
            guard var state = fileStates[path] else { continue }
            state.isCollapsed = collapsed || (state.file.isLarge && state.hunks.isEmpty)
            fileStates[path] = state
        }
    }

    private func toggleFile(path: String) {
        guard var state = fileStates[path] else { return }
        state.isCollapsed.toggle()
        fileStates[path] = state
    }

    private func toggleViewed(path: String) {
        guard var state = fileStates[path] else { return }
        state.isViewed.toggle()
        if state.isViewed { state.isCollapsed = true }
        let key = ViewedFileKey(workspaceID: workspace.workspaceID, path: path, patchDigest: state.file.patchDigest)
        viewedStore.setViewed(state.isViewed, for: key)
        fileStates[path] = state
    }

    private func copyPath(_ path: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = path
        #endif
    }

    private func cancelHighlighting() {
        for task in highlightTasks.values { task.cancel() }
        highlightTasks.removeAll()
    }

    private func errorSnapshot(_ error: any Error) -> ChangesErrorSnapshot {
        let detail = String(describing: error).lowercased()
        if detail.contains("auth") || detail.contains("unauthorized") || detail.contains("forbidden") {
            return ChangesErrorSnapshot(
                kind: .authentication,
                title: String(localized: "diff.error.auth.title", defaultValue: "Sign-in required", bundle: .module),
                message: String(localized: "diff.error.auth.message", defaultValue: "Reconnect to your Mac and try again.", bundle: .module)
            )
        }
        if detail.contains("capability") || detail.contains("unsupported") || detail.contains("method not found") {
            return ChangesErrorSnapshot(
                kind: .capability,
                title: String(localized: "diff.error.capability.title", defaultValue: "Update cmux on your Mac", bundle: .module),
                message: String(localized: "diff.error.capability.message", defaultValue: "This Mac doesn’t support native changes yet.", bundle: .module)
            )
        }
        if detail.contains("baseline") || detail.contains("last turn") || detail.contains("merge base") {
            return ChangesErrorSnapshot(
                kind: .baseline,
                title: String(localized: "diff.error.baseline.title", defaultValue: "Baseline unavailable", bundle: .module),
                message: String(localized: "diff.error.baseline.message", defaultValue: "Choose another comparison base and try again.", bundle: .module)
            )
        }
        return ChangesErrorSnapshot(
            kind: .general,
            title: String(localized: "diff.error.general.title", defaultValue: "Couldn’t load changes", bundle: .module),
            message: String(localized: "diff.error.general.message", defaultValue: "Check the connection to your Mac and try again.", bundle: .module)
        )
    }
}
