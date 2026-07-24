#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileChanges
import CmuxMobileShell
import Foundation
import SwiftUI
import UIKit

/// Full-height navigation sheet binding workspace RPC data to value-driven changes views.
public struct WorkspaceChangesSheet: View {
    @Bindable private var store: CMUXMobileShellStore
    private let workspaceID: String
    private let workspaceTitle: String
    private let fontPreference: DiffFontPreference
    @State private var branch = ""
    @State private var base = "HEAD"
    @State private var totals = ChangesTotals(filesChanged: 0, additions: 0, deletions: 0)
    @State private var files: [ChangedFileItem] = []
    @State private var listState: WorkspaceChangesListState = .loading
    @State private var presentationCache = FileDiffPresentationCache()
    @State private var fontSize: Double
    @State private var navigationPath: [WorkspaceChangesNavigationRoute] = []
    @State private var inlineActionHost = ChatArtifactInlineActionHost()
    @Environment(\.dismiss) private var dismiss

    /// Creates a changes sheet for one remote workspace.
    /// - Parameters:
    ///   - store: Connected mobile shell store.
    ///   - workspaceID: Remote workspace UUID string.
    ///   - workspaceTitle: Workspace title used when a branch name is unavailable.
    public init(
        store: CMUXMobileShellStore,
        workspaceID: String,
        workspaceTitle: String
    ) {
        self.store = store
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        let preference = DiffFontPreference(defaults: .standard)
        fontPreference = preference
        _fontSize = State(initialValue: preference.pointSize)
    }

    public var body: some View {
        WorkspaceChangesNavigationView(
            branch: branch,
            base: base,
            totals: totals,
            files: files,
            listState: listState,
            cachedPresentations: presentationCache.presentations,
            fontSize: fontSize,
            listActions: listActions,
            pagerActions: pagerActions,
            inlineActionHost: inlineActionHost,
            path: $navigationPath,
            onClose: { dismiss() }
        )
        .task(id: workspaceID) {
            await loadChangedFiles(invalidateCache: true)
        }
    }

    private var listActions: WorkspaceChangesListActions {
        WorkspaceChangesListActions(
            onSelectFile: { _ in },
            onRefresh: { await loadChangedFiles(invalidateCache: true) },
            onRetry: { Task { await loadChangedFiles(invalidateCache: true) } }
        )
    }

    private var pagerActions: WorkspaceFileDiffPagerActions {
        let loadDocument: @MainActor @Sendable (String, Bool, Int?) async throws -> FileDiffPresentation = {
            path,
            forceRefresh,
            maxLines in
            try await self.loadDocument(
                path: path,
                forceRefresh: forceRefresh,
                maxLines: maxLines
            )
        }
        let loadCurrentLines: @MainActor @Sendable (String) async throws -> DiffExpansionCurrentFile =
            store.workspaceChangesCurrentFileLinesLoader(workspaceID: workspaceID)
        let presentationAccess: @MainActor @Sendable (String) -> Void = { path in
            presentationCache.touch(path: path)
        }
        let persistFontSize: @MainActor @Sendable (Double) -> Void = { pointSize in
            fontSize = pointSize
            fontPreference.pointSize = pointSize
        }
        let copy: @MainActor @Sendable (String) -> Void = { text in
            UIPasteboard.general.string = text
        }
        let inlinePreview: @MainActor @Sendable (Int, FileDiffPreviewRevision) -> AnyView = {
            index,
            revision in
            inlineArtifactPreview(index: index, revision: revision)
        }
        return WorkspaceFileDiffPagerActions(
            onLoad: loadDocument,
            onLoadCurrentLines: loadCurrentLines,
            onPresentationAccess: presentationAccess,
            onPersistFontSize: persistFontSize,
            onCopy: copy,
            inlinePreview: inlinePreview
        )
    }

    @MainActor
    private func inlineArtifactPreview(
        index: Int,
        revision: FileDiffPreviewRevision
    ) -> AnyView {
        guard files.indices.contains(index) else {
            return AnyView(EmptyView())
        }
        let file = files[index]
        let resolvedPath = revision == .base ? (file.oldPath ?? file.path) : file.path
        let loader = store.workspaceChangesArtifactLoader(
            workspaceID: workspaceID,
            path: file.path,
            oldPath: file.oldPath,
            revision: revision
        )
        return AnyView(
            ChatArtifactInlineViewer(
                path: resolvedPath,
                actionHost: inlineActionHost
            )
            .environment(\.chatArtifactLoader, loader)
            .id("\(revision.rawValue)\u{0}\(resolvedPath)")
        )
    }

    @MainActor
    private func loadChangedFiles(invalidateCache: Bool) async {
        if invalidateCache { presentationCache.removeAll() }
        listState = .loading
        do {
            let response = try await store.fetchChangedFiles(workspaceID: workspaceID)
            guard !Task.isCancelled else { return }
            branch = response.branch ?? workspaceTitle
            base = response.baseRef ?? "HEAD"
            totals = ChangesTotals(
                filesChanged: response.filesChanged,
                additions: response.additions,
                deletions: response.deletions
            )
            files = response.files.map { file in
                ChangedFileItem(
                    path: file.path,
                    oldPath: file.oldPath,
                    kind: file.status.fileChangeKind,
                    additions: file.additions,
                    deletions: file.deletions,
                    isBinary: file.isBinary,
                    isApproximate: file.isApproximate
                )
            }
            listState = files.isEmpty
                ? .empty
                : .loaded(truncated: response.truncated)
        } catch is CancellationError {
            guard RecoverableCancellationErrorPolicy().shouldPublishFailure(
                taskIsCancelled: Task.isCancelled
            ) else { return }
            listState = .error
        } catch WorkspaceChangesFetchError.notARepository {
            guard !Task.isCancelled else { return }
            files = []
            totals = ChangesTotals(filesChanged: 0, additions: 0, deletions: 0)
            listState = .notARepository
        } catch {
            guard !Task.isCancelled else { return }
            listState = .error
        }
    }

    @MainActor
    private func loadDocument(
        path: String,
        forceRefresh: Bool,
        maxLines: Int?
    ) async throws -> FileDiffPresentation {
        if maxLines == nil,
           !forceRefresh,
           let cached = presentationCache.presentation(forPath: path) {
            return cached
        }
        let response = try await store.fetchFileDiff(
            workspaceID: workspaceID,
            path: path,
            maxLines: maxLines
        )
        let presentation = await UnifiedDiffParser().parsePresentationOffMain(
            response.unifiedDiff,
            truncated: response.truncated,
            isBinary: response.isBinary,
            totalLineCount: response.diffTotalLines,
            contentFingerprint: response.contentFingerprint,
            fileKind: response.status.fileChangeKind
        )
        try Task.checkCancellation()
        if maxLines == nil {
            presentationCache.insert(presentation, forPath: path)
        }
        return presentation
    }
}
#endif
