import Darwin
import Foundation


// MARK: - Deferred Diff Viewer Completion
extension CMUXCLI {
    func completeDeferredDiffViewer(_ viewer: DiffViewerWriteResult) throws -> DiffViewerWriteResult {
        do {
            if let completeDeferred = viewer.completeDeferred {
                return try completeDeferred()
            }
            let selectedCompletion = try completeDeferredDiffViewerSources(
                viewer.deferredSourceSet,
                selectedURL: viewer.fileURL
            )
            guard let selectedCompletion else { return viewer }
            var finalized = viewer
            finalized.fileURL = selectedCompletion.fileURL
            finalized.url = selectedCompletion.viewerURL
            finalized.input = selectedCompletion.input
            finalized.title = selectedCompletion.input.defaultTitle
            return finalized
        } catch {
            throw diffViewerCommandError(error)
        }
    }

    func completeDeferredDiffViewerSelectedSource(
        _ sourceSet: DiffViewerDeferredSourceSet?,
        selectedURL: URL
    ) throws -> DiffViewerDeferredCompletion? {
        guard let sourceSet else { return nil }
        guard let page = sourceSet.pages.first(where: { $0.url == selectedURL }) else {
            return nil
        }
        do {
            return try completeDeferredDiffViewerSource(page, sourceSet: sourceSet)
        } catch {
            writeDeferredDiffViewerError(error, page: page, sourceSet: sourceSet)
            throw error
        }
    }

    func completeDeferredDiffViewerSources(
        _ sourceSet: DiffViewerDeferredSourceSet?,
        selectedURL: URL? = nil,
        completedPageURLs initialCompletedPageURLs: Set<URL> = []
    ) throws -> DiffViewerDeferredCompletion? {
        guard let sourceSet else { return nil }
        var completedPageURLs = initialCompletedPageURLs
        var selectedCompletion: DiffViewerDeferredCompletion?
        var selectedError: Error?
        for page in sourceSet.pages {
            guard !completedPageURLs.contains(page.url) else { continue }
            do {
                let completion = try completeDeferredDiffViewerSource(page, sourceSet: sourceSet)
                completedPageURLs.formUnion(completion.completedPageURLs)
                if page.url == selectedURL {
                    selectedCompletion = completion
                }
            } catch {
                writeDeferredDiffViewerError(error, page: page, sourceSet: sourceSet)
                if page.url == selectedURL {
                    selectedError = error
                }
            }
        }
        if let selectedError {
            throw selectedError
        }
        return selectedCompletion
    }

    private func writeDeferredDiffViewerError(
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
            runtime: sourceSet.runtime
        )
    }

    private func completeDeferredDiffViewerSource(
        _ page: DiffViewerDeferredSourcePage,
        sourceSet: DiffViewerDeferredSourceSet
    ) throws -> DiffViewerDeferredCompletion {
        do {
            return try writeDeferredDiffViewerSource(
                page: page,
                source: page.source,
                context: page.context,
                sourceOptions: page.sourceOptions,
                repoOptions: page.repoOptions,
                baseOptions: page.baseOptions,
                sourceSet: sourceSet
            )
        } catch let error as EmptyDiffSourceError where page.allowsSourceFallback {
            for source in DiffSource.allCases where source != page.source {
                guard let fallback = page.sourceFallbacks[source] else { continue }
                do {
                    let fallbackPage = DiffViewerDeferredSourcePage(
                        source: source,
                        url: fallback.url,
                        viewerURL: fallback.viewerURL,
                        titleOverride: page.titleOverride,
                        context: fallback.context,
                        sourceOptions: fallback.sourceOptions,
                        repoOptions: fallback.repoOptions,
                        baseOptions: fallback.baseOptions
                    )
                    var completion = try writeDeferredDiffViewerSource(
                        page: fallbackPage,
                        source: source,
                        context: fallback.context,
                        sourceOptions: fallback.sourceOptions,
                        repoOptions: fallback.repoOptions,
                        baseOptions: fallback.baseOptions,
                        sourceSet: sourceSet
                    )
                    // The originally selected source is empty; leave its own page as
                    // a friendly empty state so switching back to it never shows a
                    // raw error. This is a secondary page (the fallback page is the
                    // returned result), so a write failure here is best-effort.
                    try? writeDiffViewerEmptyStatePage(message: error.message, page: page, sourceSet: sourceSet)
                    completion.completedPageURLs.insert(page.url)
                    return completion
                } catch is EmptyDiffSourceError {
                    continue
                } catch let fallbackError {
                    throw fallbackError
                }
            }
            // No source has changes: render the selected source's friendly empty
            // state. A write failure must propagate so the deferred pipeline does
            // not report success while a stale loading page remains.
            try writeDiffViewerEmptyStatePage(message: error.message, page: page, sourceSet: sourceSet)
            return deferredDiffViewerEmptyStateCompletion(message: error.message, page: page)
        } catch let error as EmptyDiffSourceError {
            // Sources that never fall back (last turn) still render their own
            // friendly empty state rather than surfacing a developer-facing error.
            try writeDiffViewerEmptyStatePage(message: error.message, page: page, sourceSet: sourceSet)
            return deferredDiffViewerEmptyStateCompletion(message: error.message, page: page)
        }
    }

    /// Writes the friendly, non-error empty diff state for a deferred source page.
    ///
    /// Used when a source has no changes to show: the panel renders plain-language
    /// text plus the source switcher instead of a raw error, and the CLI exits
    /// successfully so the launcher never emits an error beep. Throws if the
    /// replacement page cannot be written, so callers never report success while a
    /// stale loading page remains.
    private func writeDiffViewerEmptyStatePage(
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
            runtime: sourceSet.runtime
        )
    }

    /// Builds the completion describing a rendered empty diff state for a deferred
    /// source page. Pure value construction; the page must already be written via
    /// ``writeDiffViewerEmptyStatePage(message:page:sourceSet:)``.
    private func deferredDiffViewerEmptyStateCompletion(
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

    private func writeDeferredDiffViewerSource(
        page: DiffViewerDeferredSourcePage,
        source: DiffSource,
        context: DiffSourceContext,
        sourceOptions: [DiffViewerSourceOption],
        repoOptions: [DiffViewerSourceOption],
        baseOptions: [DiffViewerSourceOption],
        sourceSet: DiffViewerDeferredSourceSet
    ) throws -> DiffViewerDeferredCompletion {
        var pageContext = context
        if source == .branch {
            let repoRoot = try gitRepoRootForDiff(pageContext)
            pageContext.repoRoot = repoRoot
            pageContext.branchBaseRef = try resolvedGitBranchDiffBaseRef(pageContext.branchBaseRef, in: repoRoot)
        }
        let input = try nonEmptyGitDiffInput(source: source, context: pageContext)
        try writeDiffViewerHTML(
            to: page.url,
            patch: input.patch,
            title: page.titleOverride ?? input.defaultTitle,
            sourceLabel: input.sourceLabel,
            externalURL: input.externalURL,
            remotePatchURL: input.remotePatchURL,
            layout: sourceSet.layout,
            layoutSource: sourceSet.layoutSource,
            appearance: sourceSet.appearance,
            sourceOptions: sourceOptions,
            repoOptions: repoOptions,
            baseOptions: baseOptions,
            repoRoot: pageContext.repoRoot,
            branchBaseRef: source == .branch ? pageContext.branchBaseRef : nil,
            runtime: sourceSet.runtime
        )
        return DiffViewerDeferredCompletion(
            input: input,
            fileURL: page.url,
            viewerURL: page.viewerURL,
            completedPageURLs: [page.url]
        )
    }

    func nonEmptyGitDiffInput(source: DiffSource, context: DiffSourceContext) throws -> DiffInput {
        let input = try readGitDiffInput(source: source, context: context)
        guard !input.patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmptyDiffSourceError(message: input.emptyMessage ?? "No changes to diff.")
        }
        return input
    }

    func diffViewerErrorMessage(_ error: Error) -> String {
        if let error = error as? CLIError {
            return error.message
        }
        if let error = error as? EmptyDiffSourceError {
            return error.message
        }
        return error.localizedDescription
    }

    private func diffViewerCommandError(_ error: Error) -> Error {
        if let error = error as? EmptyDiffSourceError {
            return CLIError(message: error.message)
        }
        return error
    }

}
