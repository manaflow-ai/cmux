import Foundation

// Deferred diff-viewer page completion support: per-repo smart branch-base
// resolution deferred until after the loading page first paints, plus the
// shared error/empty-state page writers used when a deferred page completes.
extension CMUXCLI {
    struct DiffViewerResolvedBranchBase {
        var ref: String
        var pickerBase: DiffBranchBase
    }

    final class DiffViewerBranchBaseResolutionCache {
        var basesByRepo: [String: DiffViewerResolvedBranchBase] = [:]
    }

    /// Reassemble the `branchPicker` payload for a deferred branch page from its
    /// stored base plus the source set's origin/groupID, or nil when not a
    /// branch page or the set lacks an origin/group.
    func deferredDiffViewerBranchPicker(
        page: DiffViewerDeferredSourcePage,
        sourceSet: DiffViewerDeferredSourceSet
    ) -> [String: Any]? {
        guard sourceSet.sessionPersisted,
              page.source == .branch,
              let base = page.branchPickerBase,
              let origin = sourceSet.origin,
              let groupID = sourceSet.groupID,
              let token = sourceSet.token,
              let repoRoot = page.context.repoRoot else {
            return nil
        }
        return diffViewerBranchPickerPayload(
            base: base,
            repoRoot: repoRoot,
            groupID: groupID,
            origin: origin,
            token: token
        )
    }

    func writeDeferredDiffViewerPlaceholder(
        page: DiffViewerDeferredSourcePage,
        sourceSet: DiffViewerDeferredSourceSet
    ) throws {
        guard !page.placeholderWritten else { return }
        let branchBaseRef = page.source == .branch && !page.resolveBranchBaseOnComplete
            ? page.context.branchBaseRef
            : nil
        let branchPicker = page.source == .branch && !page.resolveBranchBaseOnComplete
            ? deferredDiffViewerBranchPicker(page: page, sourceSet: sourceSet)
            : nil
        try writeDiffViewerStatusHTML(
            to: page.url,
            title: page.placeholderTitle,
            sourceLabel: "git \(page.source.slug)",
            message: page.placeholderMessage,
            isError: false,
            pollForReplacement: true,
            layout: sourceSet.layout,
            layoutSource: sourceSet.layoutSource,
            appearance: sourceSet.appearance,
            sourceOptions: page.sourceOptions,
            repoOptions: page.repoOptions,
            baseOptions: page.placeholderBaseOptions,
            repoRoot: page.context.repoRoot,
            branchBaseRef: branchBaseRef,
            branchPicker: branchPicker,
            runtime: sourceSet.runtime
        )
    }

    func resolvedDeferredDiffViewerBranchBase(
        repoRoot: String,
        sourceSet: DiffViewerDeferredSourceSet
    ) throws -> DiffViewerResolvedBranchBase {
        if let cached = sourceSet.branchBaseCache.basesByRepo[repoRoot] {
            return cached
        }
        let resolved: DiffViewerResolvedBranchBase
        if let smart = try? resolvedDiffBranchBase(sourceSet.explicitBranchBaseRef, in: repoRoot) {
            resolved = DiffViewerResolvedBranchBase(ref: smart.ref, pickerBase: smart)
        } else {
            let ref = try resolvedGitBranchDiffBaseRef(sourceSet.explicitBranchBaseRef, in: repoRoot)
            let hasExplicitBase = sourceSet.explicitBranchBaseRef?.isEmpty == false
            resolved = DiffViewerResolvedBranchBase(
                ref: ref,
                pickerBase: DiffBranchBase(
                    ref: ref,
                    reason: hasExplicitBase ? DiffBranchBaseReason.manual : DiffBranchBaseReason.default,
                    confidence: hasExplicitBase ? "high" : "low"
                )
            )
        }
        sourceSet.branchBaseCache.basesByRepo[repoRoot] = resolved
        return resolved
    }

    func preparedDeferredDiffViewerSourcePage(
        _ page: DiffViewerDeferredSourcePage,
        sourceSet: DiffViewerDeferredSourceSet
    ) throws -> DiffViewerDeferredSourcePage {
        guard page.source == .branch else { return page }
        var prepared = page
        let repoRoot = try gitRepoRootForDiff(prepared.context)
        prepared.context.repoRoot = repoRoot
        if prepared.resolveBranchBaseOnComplete {
            let resolved = try resolvedDeferredDiffViewerBranchBase(repoRoot: repoRoot, sourceSet: sourceSet)
            prepared.context.branchBaseRef = resolved.ref
            prepared.branchPickerBase = resolved.pickerBase
            prepared.resolveBranchBaseOnComplete = false
        } else {
            prepared.context.branchBaseRef = try resolvedGitBranchDiffBaseRef(
                prepared.context.branchBaseRef,
                in: repoRoot
            )
        }
        return prepared
    }

    func writeDeferredDiffViewerError(
        _ error: Error,
        page: DiffViewerDeferredSourcePage,
        sourceSet: DiffViewerDeferredSourceSet
    ) {
        let message = diffViewerErrorMessage(error)
        try? writeDiffViewerStatusHTML(
            to: page.url,
            title: page.titleOverride ?? page.source.title,
            sourceLabel: "git \(page.source.slug)",
            message: message,
            isError: true,
            pollForReplacement: false,
            layout: sourceSet.layout,
            layoutSource: sourceSet.layoutSource,
            appearance: sourceSet.appearance,
            sourceOptions: page.sourceOptions,
            repoOptions: page.repoOptions,
            baseOptions: page.baseOptions,
            repoRoot: page.context.repoRoot,
            branchBaseRef: page.source == .branch ? page.context.branchBaseRef : nil,
            branchPicker: deferredDiffViewerBranchPicker(page: page, sourceSet: sourceSet),
            runtime: sourceSet.runtime
        )
    }

    /// Writes the friendly, non-error empty diff state for a deferred source page.
    ///
    /// Used when a source has no changes to show: the panel renders plain-language
    /// text plus the source switcher instead of a raw error, and the CLI exits
    /// successfully so the launcher never emits an error beep. Throws if the
    /// replacement page cannot be written, so callers never report success while a
    /// stale loading page remains.
    func writeDiffViewerEmptyStatePage(
        message: String,
        page: DiffViewerDeferredSourcePage,
        sourceSet: DiffViewerDeferredSourceSet
    ) throws {
        try writeDiffViewerStatusHTML(
            to: page.url,
            title: page.titleOverride ?? page.source.title,
            sourceLabel: "git \(page.source.slug)",
            message: message,
            isError: false,
            pollForReplacement: false,
            layout: sourceSet.layout,
            layoutSource: sourceSet.layoutSource,
            appearance: sourceSet.appearance,
            sourceOptions: page.sourceOptions,
            repoOptions: page.repoOptions,
            baseOptions: page.source == .branch ? page.baseOptions : [],
            repoRoot: page.context.repoRoot,
            branchBaseRef: page.source == .branch ? page.context.branchBaseRef : nil,
            branchPicker: deferredDiffViewerBranchPicker(page: page, sourceSet: sourceSet),
            runtime: sourceSet.runtime
        )
    }

    /// Builds the completion describing a rendered empty diff state for a deferred
    /// source page. Pure value construction; the page must already be written via
    /// ``writeDiffViewerEmptyStatePage(message:page:sourceSet:)``.
    func deferredDiffViewerEmptyStateCompletion(
        message: String,
        page: DiffViewerDeferredSourcePage
    ) -> DiffViewerDeferredCompletion {
        DiffViewerDeferredCompletion(
            input: DiffInput(
                patch: "",
                sourceLabel: "git \(page.source.slug)",
                defaultTitle: page.titleOverride ?? page.source.title,
                emptyMessage: message,
                externalURL: nil
            ),
            fileURL: page.url,
            viewerURL: page.viewerURL,
            completedPageURLs: [page.url]
        )
    }
}
