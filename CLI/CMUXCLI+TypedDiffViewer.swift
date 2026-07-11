import Foundation

extension CMUXCLI {
    /// Writes one viewer document for the typed sidecar path. Source and repo
    /// changes open a new Rust session inside that document, so the modern path
    /// does not prebuild the legacy source x repository x base page matrix.
    func writeTypedGitDiffViewerPage(
        selectedSource: DiffSource,
        titleOverride: String?,
        layout: String,
        layoutSource: String,
        appearance: DiffViewerAppearance,
        context: DiffSourceContext,
        target: DiffViewerGitHTMLSetTarget,
        extraAllowedPageURL: URL?
    ) throws -> DiffViewerWriteResult {
        let repoRoot = try gitRepoRootForDiff(context)
        let fileURL = target.directory.appendingPathComponent(
            "diff-\(target.groupID)-viewer.html",
            isDirectory: false
        )
        let viewerURL = try target.mapper.viewerURL(for: fileURL)
        let assets = try ensureDiffViewerAssets(nextTo: fileURL, runtime: target.runtime)
        let sharedPayload = DiffViewerSharedPayload(
            labels: DiffViewerLabels.localized().jsonObject,
            shortcuts: diffViewerShortcutPayload(),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
        let repoCandidates = gitDiffViewerRepoOptions(selectedRepoRoot: repoRoot, context: context)
        let session = DiffViewerBranchSession(
            token: target.mapper.token,
            groupID: target.groupID,
            repoRoot: repoRoot,
            allowedRepoRoots: repoCandidates.map(\.repoRoot),
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            titleOverride: titleOverride,
            workspaceId: context.workspaceId,
            surfaceId: context.surfaceId
        )
        try writeDiffViewerBranchSession(session, rootDirectory: target.directory)

        func sessionSource(_ source: DiffSource, repo: String) -> [String: Any]? {
            switch source {
            case .unstaged:
                return ["kind": "unstaged", "repoRoot": repo]
            case .staged:
                return ["kind": "staged", "repoRoot": repo]
            case .branch:
                var payload: [String: Any] = ["kind": "branch", "repoRoot": repo]
                if repo == repoRoot,
                   let base = normalizedDiffSourceValue(context.branchBaseRef) {
                    payload["baseRef"] = base
                }
                return payload
            case .lastTurn:
                guard selectedSource == .lastTurn else { return nil }
                return [
                    "kind": "patch",
                    "path": "/\(diffViewerPatchFileURL(for: fileURL).lastPathComponent)",
                ]
            }
        }
        let sourceOptions = DiffSource.allCases.map { source in
            let typedSource = sessionSource(source, repo: repoRoot)
            return DiffViewerSourceOption(
                value: source.slug,
                label: source.menuLabel,
                selected: source == selectedSource,
                url: nil,
                disabled: typedSource == nil && source != selectedSource,
                message: nil,
                sourceLabel: nil,
                sessionSource: typedSource
            )
        }
        let repoOptions: [DiffViewerSourceOption]
        if repoCandidates.count > 1, selectedSource != .lastTurn {
            repoOptions = repoCandidates.map { option in
                DiffViewerSourceOption(
                    value: option.repoRoot,
                    label: option.label,
                    selected: option.repoRoot == repoRoot,
                    url: nil,
                    disabled: false,
                    message: option.repoRoot,
                    sourceLabel: nil,
                    sessionSource: sessionSource(selectedSource, repo: option.repoRoot)
                )
            }
        } else {
            repoOptions = []
        }

        let responseInput: DiffInput
        if selectedSource == .lastTurn {
            do {
                responseInput = try nonEmptyGitDiffInput(source: selectedSource, context: context)
                try writeDiffViewerHTML(
                    to: fileURL,
                    patch: responseInput.patch,
                    title: titleOverride ?? responseInput.defaultTitle,
                    sourceLabel: responseInput.sourceLabel,
                    externalURL: responseInput.externalURL,
                    remotePatchURL: responseInput.remotePatchURL,
                    layout: layout,
                    layoutSource: layoutSource,
                    appearance: appearance,
                    sourceOptions: sourceOptions,
                    repoOptions: repoOptions,
                    repoRoot: repoRoot,
                    assets: assets,
                    sharedPayload: sharedPayload,
                    runtime: target.runtime
                )
            } catch let error as EmptyDiffSourceError {
                responseInput = DiffInput(
                    patch: "",
                    sourceLabel: "git \(selectedSource.slug)",
                    defaultTitle: selectedSource.title,
                    emptyMessage: error.message,
                    externalURL: nil
                )
                try writeDiffViewerStatusHTML(
                    to: fileURL,
                    title: titleOverride ?? selectedSource.title,
                    sourceLabel: responseInput.sourceLabel,
                    message: error.message,
                    isError: false,
                    pollForReplacement: false,
                    layout: layout,
                    layoutSource: layoutSource,
                    appearance: appearance,
                    sourceOptions: sourceOptions,
                    repoOptions: repoOptions,
                    repoRoot: repoRoot,
                    assets: assets,
                    sharedPayload: sharedPayload,
                    runtime: target.runtime
                )
            }
        } else {
            let selectedSessionSource = sessionSource(selectedSource, repo: repoRoot)
            responseInput = DiffInput(
                patch: "",
                sourceLabel: "git \(selectedSource.slug)",
                defaultTitle: selectedSource.title,
                emptyMessage: selectedSource.emptyMessage,
                externalURL: nil
            )
            try writeDiffViewerStatusHTML(
                to: fileURL,
                title: titleOverride ?? selectedSource.title,
                sourceLabel: responseInput.sourceLabel,
                message: diffViewerLoadingDiffMessage(selectedSource.menuLabel),
                emptyMessage: selectedSource.emptyMessage,
                isError: false,
                pollForReplacement: true,
                layout: layout,
                layoutSource: layoutSource,
                appearance: appearance,
                sourceOptions: sourceOptions,
                repoOptions: repoOptions,
                repoRoot: repoRoot,
                branchBaseRef: context.branchBaseRef,
                sessionSource: selectedSessionSource,
                capabilityToken: target.mapper.token,
                assets: assets,
                sharedPayload: sharedPayload,
                runtime: target.runtime
            )
        }

        var pageURLs = [fileURL]
        if let extraAllowedPageURL { pageURLs.append(extraAllowedPageURL) }
        let allowedFiles = try diffViewerAllowedFiles(
            pageURLs: pageURLs,
            assets: assets,
            mapper: target.mapper
        )
        try writeDiffViewerHTTPManifest(
            token: target.mapper.token,
            files: allowedFiles,
            rootDirectory: target.directory
        )
        return DiffViewerWriteResult(
            fileURL: fileURL,
            url: viewerURL,
            title: titleOverride ?? responseInput.defaultTitle,
            input: responseInput,
            allowedFiles: allowedFiles
        )
    }
}
