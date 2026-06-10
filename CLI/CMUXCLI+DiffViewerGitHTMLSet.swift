import Darwin
import Foundation


// MARK: - Git Diff Viewer HTML Set Writing
extension CMUXCLI {
    func writeGitDiffViewerHTMLSet(
        selectedSource: DiffSource,
        titleOverride: String?,
        layout: String,
        layoutSource: String,
        appearance: DiffViewerAppearance,
        context: DiffSourceContext,
        runtime: URL?
    ) throws -> DiffViewerWriteResult {
        let target = try makeDiffViewerGitHTMLSetTarget(runtime: runtime)
        if selectedSource != .lastTurn {
            return try writeOpeningGitDiffViewerHTMLSet(
                selectedSource: selectedSource,
                titleOverride: titleOverride,
                layout: layout,
                layoutSource: layoutSource,
                appearance: appearance,
                context: context,
                target: target
            )
        }
        return try writeCompleteGitDiffViewerHTMLSet(
            selectedSource: selectedSource,
            titleOverride: titleOverride,
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            context: context,
            target: target
        )
    }

    private func makeDiffViewerGitHTMLSetTarget(runtime: URL?) throws -> DiffViewerGitHTMLSetTarget {
        let directory = try diffViewerDirectory()
        let origin = try diffViewerHTTPServerOrigin(rootDirectory: directory, runtime: runtime)
        let mapper = DiffViewerURLMapper(
            token: UUID().uuidString.lowercased(),
            rootDirectory: directory,
            origin: origin
        )
        let timestamp = Int(Date().timeIntervalSince1970)
        let groupID = "\(timestamp)-\(UUID().uuidString.prefix(8))"
        return DiffViewerGitHTMLSetTarget(directory: directory, mapper: mapper, groupID: groupID, runtime: runtime)
    }

    private func diffViewerLoadingDiffMessage(_ target: String) -> String {
        let format = CMUXDiffViewerLocalization.string(
            "diffViewer.loadingDiffTarget",
            defaultValue: "Loading diff: %@"
        )
        return String(format: format, locale: Locale.current, target)
    }

    private func writeOpeningGitDiffViewerHTMLSet(
        selectedSource: DiffSource,
        titleOverride: String?,
        layout: String,
        layoutSource: String,
        appearance: DiffViewerAppearance,
        context: DiffSourceContext,
        target: DiffViewerGitHTMLSetTarget
    ) throws -> DiffViewerWriteResult {
        let directory = target.directory
        let mapper = target.mapper
        let groupID = target.groupID
        let repoRoot = try gitRepoRootForDiff(context)
        let openingFileURL = directory.appendingPathComponent(
            "diff-\(groupID)-opening.html",
            isDirectory: false
        )
        let openingURL = try mapper.viewerURL(for: openingFileURL)
        let sourceLabel = "git \(selectedSource.slug)"
        let title = titleOverride ?? selectedSource.title
        let message = diffViewerLoadingDiffMessage(selectedSource.menuLabel)
        try writeDiffViewerStatusHTML(
            to: openingFileURL,
            title: title,
            sourceLabel: sourceLabel,
            message: message,
            isError: false,
            pollForReplacement: true,
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            sourceOptions: [],
            repoOptions: [],
            baseOptions: [],
            repoRoot: repoRoot,
            branchBaseRef: selectedSource == .branch ? context.branchBaseRef : nil,
            runtime: target.runtime
        )
        let assets = try ensureDiffViewerAssets(nextTo: openingFileURL, runtime: target.runtime)
        let allowedFiles = try diffViewerAllowedFiles(
            pageURLs: [openingFileURL],
            assets: assets,
            mapper: mapper
        )
        try writeDiffViewerHTTPManifest(
            token: mapper.token,
            files: allowedFiles,
            rootDirectory: directory
        )

        let responseInput = DiffInput(
            patch: "",
            sourceLabel: sourceLabel,
            defaultTitle: selectedSource.title,
            emptyMessage: selectedSource.emptyMessage,
            externalURL: nil
        )
        return DiffViewerWriteResult(
            fileURL: openingFileURL,
            url: openingURL,
            title: title,
            input: responseInput,
            allowedFiles: allowedFiles,
            completeDeferred: { [self] in
                do {
                    let completed = try writeCompleteGitDiffViewerHTMLSet(
                        selectedSource: selectedSource,
                        titleOverride: titleOverride,
                        layout: layout,
                        layoutSource: layoutSource,
                        appearance: appearance,
                        context: context,
                        target: target,
                        extraAllowedPageURL: openingFileURL
                    )
                    var finalized = completed

                    var completedPageURLs = Set<URL>()
                    do {
                        if let selectedCompletion = try completeDeferredDiffViewerSelectedSource(
                            completed.deferredSourceSet,
                            selectedURL: completed.fileURL
                        ) {
                            completedPageURLs.formUnion(selectedCompletion.completedPageURLs)
                            finalized.fileURL = selectedCompletion.fileURL
                            finalized.url = selectedCompletion.viewerURL
                            finalized.input = selectedCompletion.input
                            finalized.title = titleOverride ?? selectedCompletion.input.defaultTitle
                        }
                    } catch {
                        try? writeDiffViewerRedirectHTML(
                            to: openingFileURL,
                            title: title,
                            targetURL: completed.url,
                            appearance: appearance,
                            runtime: target.runtime
                        )
                        throw error
                    }
                    try writeDiffViewerRedirectHTML(
                        to: openingFileURL,
                        title: finalized.title,
                        targetURL: finalized.url,
                        appearance: appearance,
                        runtime: target.runtime
                    )
                    _ = try completeDeferredDiffViewerSources(
                        completed.deferredSourceSet,
                        selectedURL: completed.fileURL,
                        completedPageURLs: completedPageURLs
                    )
                    return finalized
                } catch {
                    let message = diffViewerErrorMessage(error)
                    try? writeDiffViewerStatusHTML(
                        to: openingFileURL,
                        title: title,
                        sourceLabel: sourceLabel,
                        message: message,
                        isError: true,
                        pollForReplacement: false,
                        layout: layout,
                        layoutSource: layoutSource,
                        appearance: appearance,
                        sourceOptions: [],
                        repoOptions: [],
                        baseOptions: [],
                        repoRoot: repoRoot,
                        branchBaseRef: selectedSource == .branch ? context.branchBaseRef : nil,
                        runtime: target.runtime
                    )
                    throw error
                }
            }
        )
    }

    private func writeCompleteGitDiffViewerHTMLSet(
        selectedSource: DiffSource,
        titleOverride: String?,
        layout: String,
        layoutSource: String,
        appearance: DiffViewerAppearance,
        context: DiffSourceContext,
        target: DiffViewerGitHTMLSetTarget,
        extraAllowedPageURL: URL? = nil
    ) throws -> DiffViewerWriteResult {
        let directory = target.directory
        let mapper = target.mapper
        let groupID = target.groupID
        let requestedSource = selectedSource
        let repoRoot = try gitRepoRootForDiff(context)
        let explicitBranchBaseRef = normalizedDiffSourceValue(context.branchBaseRef)
        var selectedSource = requestedSource
        let shouldDeferSelectedSource = requestedSource != .lastTurn
        func sourceContext(for source: DiffSource, repoRoot: String) throws -> DiffSourceContext {
            var sourceContext = context
            sourceContext.repoRoot = repoRoot
            if source == .branch {
                sourceContext.branchBaseRef = try resolvedGitBranchDiffBaseRef(
                    sourceContext.branchBaseRef,
                    in: repoRoot
                )
            } else {
                sourceContext.branchBaseRef = nil
            }
            return sourceContext
        }
        var selectedContext = try sourceContext(for: selectedSource, repoRoot: repoRoot)
        var selectedInput: DiffInput?
        // When non-nil, the selected source has no changes: render the friendly,
        // non-error empty diff state (with the source switcher) instead of failing.
        var selectedEmptyMessage: String?
        if !shouldDeferSelectedSource {
            do {
                selectedInput = try nonEmptyGitDiffInput(source: selectedSource, context: selectedContext)
            } catch let error as EmptyDiffSourceError {
                if selectedSource == .lastTurn {
                    // Last turn is the user's explicit intent, so never silently
                    // switch sources; show its empty state and keep the switcher.
                    selectedEmptyMessage = error.message
                    selectedInput = nil
                } else {
                    var fallback: (source: DiffSource, context: DiffSourceContext, input: DiffInput)?
                    for candidate in DiffSource.allCases where candidate != selectedSource {
                        guard let candidateContext = try? sourceContext(for: candidate, repoRoot: repoRoot),
                              let candidateInput = try? nonEmptyGitDiffInput(source: candidate, context: candidateContext) else {
                            continue
                        }
                        fallback = (candidate, candidateContext, candidateInput)
                        break
                    }
                    if let fallback {
                        selectedSource = fallback.source
                        selectedContext = fallback.context
                        selectedInput = fallback.input
                    } else {
                        // Every source is empty: show the originally selected
                        // source's empty state rather than a raw error.
                        selectedEmptyMessage = error.message
                        selectedInput = nil
                    }
                }
            }
        }
        let fileURLs = Dictionary(uniqueKeysWithValues: DiffSource.allCases.map { source in
            (
                source,
                directory.appendingPathComponent(
                    "diff-\(groupID)-\(source.slug).html",
                    isDirectory: false
                )
            )
        })
        let urls = Dictionary(uniqueKeysWithValues: try fileURLs.map { source, fileURL in
            (source, try mapper.viewerURL(for: fileURL))
        })
        let sourceOptions = diffViewerSourceOptions(selected: selectedSource, urls: urls)
        guard let selectedFileURL = fileURLs[selectedSource],
              let selectedURL = urls[selectedSource] else {
            throw CLIError(message: "Failed to write diff viewer")
        }
        let repoCandidates = gitDiffViewerRepoOptions(selectedRepoRoot: repoRoot)
        let repoFileURLsBySource: [DiffSource: [String: URL]] = Dictionary(uniqueKeysWithValues: DiffSource.allCases.map { source in
            let fileURLsByRepo = Dictionary(uniqueKeysWithValues: repoCandidates.enumerated().map { index, option in
                if option.repoRoot == repoRoot, let fileURL = fileURLs[source] {
                    return (option.repoRoot, fileURL)
                }
                return (
                    option.repoRoot,
                    directory.appendingPathComponent(
                        "diff-\(groupID)-repo-\(index)-\(source.slug).html",
                        isDirectory: false
                    )
                )
            })
            return (source, fileURLsByRepo)
        })
        let repoURLsBySource: [DiffSource: [String: URL]] = Dictionary(uniqueKeysWithValues: try repoFileURLsBySource.map { source, fileURLsByRepo in
            let urlsByRepo = Dictionary(uniqueKeysWithValues: try fileURLsByRepo.map { repoRoot, fileURL in
                (repoRoot, try mapper.viewerURL(for: fileURL))
            })
            return (source, urlsByRepo)
        })
        func sourceOptionsForRepo(selected source: DiffSource, selectedRepoRoot: String) -> [DiffViewerSourceOption] {
            let sourceURLs = Dictionary(uniqueKeysWithValues: DiffSource.allCases.compactMap { option -> (DiffSource, URL)? in
                guard let url = repoURLsBySource[option]?[selectedRepoRoot] else { return nil }
                return (option, url)
            })
            return diffViewerSourceOptions(selected: source, urls: sourceURLs)
        }
        func repoOptionsForSource(_ source: DiffSource, selectedRepoRoot: String) -> [DiffViewerSourceOption] {
            diffViewerRepoOptions(
                selectedRepoRoot: selectedRepoRoot,
                candidates: repoCandidates,
                urls: repoURLsBySource[source] ?? [:]
            )
        }
        let selectedRepoOptions = repoOptionsForSource(selectedSource, selectedRepoRoot: repoRoot)

        let branchBaseForOptions = try? resolvedGitBranchDiffBaseRef(selectedContext.branchBaseRef, in: repoRoot)
        let baseCandidates: [DiffViewerBranchBaseOption]
        let baseFileURLs: [String: URL]
        let baseURLs: [String: URL]
        if let branchBaseForOptions, let branchFileURL = fileURLs[.branch] {
            baseCandidates = gitDiffViewerBranchBaseOptions(
                in: repoRoot,
                selectedBaseRef: branchBaseForOptions
            )
            baseFileURLs = Dictionary(uniqueKeysWithValues: baseCandidates.enumerated().map { index, option in
                if option.ref == branchBaseForOptions {
                    return (option.ref, branchFileURL)
                }
                return (
                    option.ref,
                    directory.appendingPathComponent(
                        "diff-\(groupID)-base-\(index)-branch.html",
                        isDirectory: false
                    )
                )
            })
            baseURLs = Dictionary(uniqueKeysWithValues: try baseFileURLs.map { ref, fileURL in
                (ref, try mapper.viewerURL(for: fileURL))
            })
        } else {
            baseCandidates = []
            baseFileURLs = [:]
            baseURLs = [:]
        }
        let baseOptions = diffViewerBranchBaseOptions(
            selectedBaseRef: branchBaseForOptions,
            candidates: baseCandidates,
            urls: baseURLs
        )

        var deferredPages: [DiffViewerDeferredSourcePage] = []
        if shouldDeferSelectedSource {
            try writeDiffViewerStatusHTML(
                to: selectedFileURL,
                title: titleOverride ?? selectedSource.title,
                sourceLabel: "git \(selectedSource.slug)",
                message: diffViewerLoadingDiffMessage(selectedSource.menuLabel),
                isError: false,
                pollForReplacement: true,
                layout: layout,
                layoutSource: layoutSource,
                appearance: appearance,
                sourceOptions: sourceOptions,
                repoOptions: selectedRepoOptions,
                baseOptions: selectedSource == .branch ? baseOptions : [],
                repoRoot: repoRoot,
                branchBaseRef: selectedSource == .branch ? selectedContext.branchBaseRef : nil,
                runtime: target.runtime
            )
            let sourceFallbacks = Dictionary(uniqueKeysWithValues: DiffSource.allCases.compactMap { source -> (DiffSource, DiffViewerDeferredSourceFallback)? in
                guard source != selectedSource,
                      let fallbackContext = try? sourceContext(for: source, repoRoot: repoRoot),
                      let fallbackFileURL = fileURLs[source],
                      let fallbackViewerURL = urls[source] else {
                    return nil
                }
                return (
                    source,
                    DiffViewerDeferredSourceFallback(
                        url: fallbackFileURL,
                        viewerURL: fallbackViewerURL,
                        context: fallbackContext,
                        sourceOptions: diffViewerSourceOptions(selected: source, urls: urls),
                        repoOptions: repoOptionsForSource(source, selectedRepoRoot: repoRoot),
                        baseOptions: source == .branch ? baseOptions : []
                    )
                )
            })
            deferredPages.append(
                DiffViewerDeferredSourcePage(
                    source: selectedSource,
                    url: selectedFileURL,
                    viewerURL: selectedURL,
                    titleOverride: titleOverride,
                    context: selectedContext,
                    sourceOptions: sourceOptions,
                    repoOptions: selectedRepoOptions,
                    baseOptions: selectedSource == .branch ? baseOptions : [],
                    allowsSourceFallback: true,
                    sourceFallbacks: sourceFallbacks
                )
            )
        }
        for source in DiffSource.allCases where source != selectedSource {
            if let url = fileURLs[source] {
                var pageContext = selectedContext
                if source == .branch {
                    pageContext.branchBaseRef = branchBaseForOptions
                } else {
                    pageContext.branchBaseRef = nil
                }
                let viewerURL: URL
                if let sourceURL = urls[source] {
                    viewerURL = sourceURL
                } else {
                    viewerURL = try mapper.viewerURL(for: url)
                }
                try writeDiffViewerStatusHTML(
                    to: url,
                    title: source.title,
                    sourceLabel: "git \(source.slug)",
                    message: diffViewerLoadingDiffMessage(source.menuLabel),
                    isError: false,
                    pollForReplacement: true,
                    layout: layout,
                    layoutSource: layoutSource,
                    appearance: appearance,
                    sourceOptions: diffViewerSourceOptions(selected: source, urls: urls),
                    repoOptions: repoOptionsForSource(source, selectedRepoRoot: repoRoot),
                    baseOptions: source == .branch ? baseOptions : [],
                    repoRoot: repoRoot,
                    branchBaseRef: source == .branch ? pageContext.branchBaseRef : nil,
                    runtime: target.runtime
                )
                deferredPages.append(
                    DiffViewerDeferredSourcePage(
                        source: source,
                        url: url,
                        viewerURL: viewerURL,
                        titleOverride: nil,
                        context: pageContext,
                        sourceOptions: diffViewerSourceOptions(selected: source, urls: urls),
                        repoOptions: repoOptionsForSource(source, selectedRepoRoot: repoRoot),
                        baseOptions: source == .branch ? baseOptions : []
                    )
                )
            }
        }

        for source in DiffSource.allCases {
            for option in repoCandidates where option.repoRoot != repoRoot {
                guard let url = repoFileURLsBySource[source]?[option.repoRoot] else { continue }
                let viewerURL: URL
                if let repoURL = repoURLsBySource[source]?[option.repoRoot] {
                    viewerURL = repoURL
                } else {
                    viewerURL = try mapper.viewerURL(for: url)
                }
                let pageContext = DiffSourceContext(
                    workspaceId: selectedContext.workspaceId,
                    surfaceId: selectedContext.surfaceId,
                    repoRoot: option.repoRoot,
                    branchBaseRef: source == .branch ? explicitBranchBaseRef : selectedContext.branchBaseRef
                )
                try writeDiffViewerStatusHTML(
                    to: url,
                    title: option.label,
                    sourceLabel: "git \(source.slug)",
                    message: diffViewerLoadingDiffMessage(option.label),
                    isError: false,
                    pollForReplacement: true,
                    layout: layout,
                    layoutSource: layoutSource,
                    appearance: appearance,
                    sourceOptions: sourceOptionsForRepo(selected: source, selectedRepoRoot: option.repoRoot),
                    repoOptions: repoOptionsForSource(source, selectedRepoRoot: option.repoRoot),
                    baseOptions: [],
                    repoRoot: option.repoRoot,
                    branchBaseRef: source == .branch ? explicitBranchBaseRef : nil,
                    runtime: target.runtime
                )
                deferredPages.append(
                    DiffViewerDeferredSourcePage(
                        source: source,
                        url: url,
                        viewerURL: viewerURL,
                        titleOverride: source == selectedSource ? titleOverride : nil,
                        context: pageContext,
                        sourceOptions: sourceOptionsForRepo(selected: source, selectedRepoRoot: option.repoRoot),
                        repoOptions: repoOptionsForSource(source, selectedRepoRoot: option.repoRoot),
                        baseOptions: []
                    )
                )
            }
        }

        for option in baseCandidates where !(branchBaseForOptions.map { $0 == option.ref } ?? false) {
            guard let url = baseFileURLs[option.ref] else { continue }
            let viewerURL: URL
            if let baseURL = baseURLs[option.ref] {
                viewerURL = baseURL
            } else {
                viewerURL = try mapper.viewerURL(for: url)
            }
            var pageContext = selectedContext
            pageContext.branchBaseRef = option.ref
            try writeDiffViewerStatusHTML(
                to: url,
                title: option.label,
                sourceLabel: "git \(DiffSource.branch.slug)",
                message: diffViewerLoadingDiffMessage(option.label),
                isError: false,
                pollForReplacement: true,
                layout: layout,
                layoutSource: layoutSource,
                appearance: appearance,
                sourceOptions: diffViewerSourceOptions(selected: .branch, urls: urls),
                repoOptions: repoOptionsForSource(.branch, selectedRepoRoot: repoRoot),
                baseOptions: diffViewerBranchBaseOptions(
                    selectedBaseRef: option.ref,
                    candidates: baseCandidates,
                    urls: baseURLs
                ),
                repoRoot: repoRoot,
                branchBaseRef: option.ref,
                runtime: target.runtime
            )
            deferredPages.append(
                DiffViewerDeferredSourcePage(
                    source: .branch,
                    url: url,
                    viewerURL: viewerURL,
                    titleOverride: selectedSource == .branch ? titleOverride : nil,
                    context: pageContext,
                    sourceOptions: diffViewerSourceOptions(selected: .branch, urls: urls),
                    repoOptions: repoOptionsForSource(.branch, selectedRepoRoot: repoRoot),
                    baseOptions: diffViewerBranchBaseOptions(
                        selectedBaseRef: option.ref,
                        candidates: baseCandidates,
                        urls: baseURLs
                    )
                )
            )
        }

        if let selectedInput {
            try writeDiffViewerHTML(
                to: selectedFileURL,
                patch: selectedInput.patch,
                title: titleOverride ?? selectedInput.defaultTitle,
                sourceLabel: selectedInput.sourceLabel,
                externalURL: selectedInput.externalURL,
                remotePatchURL: selectedInput.remotePatchURL,
                layout: layout,
                layoutSource: layoutSource,
                appearance: appearance,
                sourceOptions: sourceOptions,
                repoOptions: selectedRepoOptions,
                baseOptions: selectedSource == .branch ? baseOptions : [],
                repoRoot: repoRoot,
                branchBaseRef: selectedSource == .branch ? selectedContext.branchBaseRef : nil,
                runtime: target.runtime
            )
        } else if let selectedEmptyMessage {
            // Friendly, non-error empty diff state: the panel shows plain-language
            // text plus the source switcher so the user can pick another diff.
            try writeDiffViewerStatusHTML(
                to: selectedFileURL,
                title: titleOverride ?? selectedSource.title,
                sourceLabel: "git \(selectedSource.slug)",
                message: selectedEmptyMessage,
                isError: false,
                pollForReplacement: false,
                layout: layout,
                layoutSource: layoutSource,
                appearance: appearance,
                sourceOptions: sourceOptions,
                repoOptions: selectedRepoOptions,
                baseOptions: selectedSource == .branch ? baseOptions : [],
                repoRoot: repoRoot,
                branchBaseRef: selectedSource == .branch ? selectedContext.branchBaseRef : nil,
                runtime: target.runtime
            )
        }
        let assets = try ensureDiffViewerAssets(nextTo: selectedFileURL, runtime: target.runtime)
        let pageURLs = [selectedFileURL] + deferredPages.map(\.url)
        var allowedFiles = try diffViewerAllowedFiles(
            pageURLs: pageURLs,
            assets: assets,
            mapper: mapper
        )
        if let extraAllowedPageURL {
            allowedFiles = try diffViewerAllowedFilesWithExtraPage(
                extraAllowedPageURL,
                files: allowedFiles,
                mapper: mapper
            )
        }
        try writeDiffViewerHTTPManifest(
            token: mapper.token,
            files: allowedFiles,
            rootDirectory: directory
        )

        let responseInput = selectedInput ?? DiffInput(
            patch: "",
            sourceLabel: "git \(selectedSource.slug)",
            defaultTitle: selectedSource.title,
            emptyMessage: selectedSource.emptyMessage,
            externalURL: nil
        )

        return DiffViewerWriteResult(
            fileURL: selectedFileURL,
            url: selectedURL,
            title: titleOverride ?? responseInput.defaultTitle,
            input: responseInput,
            allowedFiles: allowedFiles,
            deferredSourceSet: DiffViewerDeferredSourceSet(
                pages: deferredPages,
                layout: layout,
                layoutSource: layoutSource,
                appearance: appearance,
                runtime: target.runtime
            )
        )
    }

}
