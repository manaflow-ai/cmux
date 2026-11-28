import Foundation

extension CMUXCLI {
    /// Emits either the full branch picker or one bounded smart-base row. Rust
    /// requests the bounded form when opening a branch session so repositories
    /// with thousands of refs do not enter the initial diff-generation path.
    func runDiffViewerRefsCommand(commandArgs: [String]) throws {
        var repo: String?
        var base: String?
        var token: String?
        var suggestedOnly = false
        var index = 0
        while index < commandArgs.count {
            switch commandArgs[index] {
            case "--repo":
                guard index + 1 < commandArgs.count else { throw CLIError(message: "__diff-viewer-refs --repo requires a path") }
                repo = commandArgs[index + 1]; index += 2
            case "--base":
                guard index + 1 < commandArgs.count else { throw CLIError(message: "__diff-viewer-refs --base requires a ref") }
                base = commandArgs[index + 1]; index += 2
            case "--token":
                guard index + 1 < commandArgs.count else { throw CLIError(message: "__diff-viewer-refs --token requires a value") }
                token = commandArgs[index + 1]; index += 2
            case "--suggested-only":
                suggestedOnly = true; index += 1
            default:
                throw CLIError(message: "Unexpected __diff-viewer-refs argument: \(commandArgs[index])")
            }
        }
        guard let repo, !repo.isEmpty else {
            throw CLIError(message: "__diff-viewer-refs requires --repo")
        }
        let rootDirectory = try diffViewerDirectory()
        let repoAuthorized = if let token, !token.isEmpty {
            diffViewerTokenAllowsRepo(token, repoRoot: repo, rootDirectory: rootDirectory)
        } else {
            diffViewerRepoIsAllowed(repo, rootDirectory: rootDirectory)
        }
        guard repoAuthorized else {
            throw CLIError(message: "Repository is not in the diff viewer allow-list")
        }
        let data: Data
        if suggestedOnly {
            let groups: [[String: Any]]
            if let resolved = try? resolvedDiffBranchBase(base, in: repo) {
                groups = [[
                    "id": "suggested",
                    "label": CMUXDiffViewerLocalization.string(
                        "diffViewer.refGroup.suggested",
                        defaultValue: "Suggested"
                    ),
                    "rows": [[
                        "ref": resolved.ref,
                        "label": resolved.ref,
                        "secondary": diffBranchBaseReasonLabel(resolved.reason),
                        "reason": resolved.reason,
                        "confidence": resolved.confidence,
                    ]],
                ]]
            } else {
                groups = []
            }
            data = try JSONSerialization.data(withJSONObject: ["groups": groups], options: [.sortedKeys])
        } else {
            data = cachedDiffBranchRefGroupsPayloadForCLI(
                repoRoot: repo,
                selectedBaseRef: base,
                rootDirectory: rootDirectory
            )
        }
        cliWriteStdout(data)
        cliWriteStdout(Data("\n".utf8))
    }

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
        let lastTurnInput = try? readGitDiffInput(source: .lastTurn, context: context)

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
                guard lastTurnInput != nil else { return nil }
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
        if repoCandidates.count > 1 {
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

        var responseInput: DiffInput
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
                    sessionSource: sessionSource(.lastTurn, repo: repoRoot),
                    capabilityToken: target.mapper.token,
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
                    sessionSource: sessionSource(.lastTurn, repo: repoRoot),
                    capabilityToken: target.mapper.token,
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
            if let lastTurnInput {
                try lastTurnInput.patch.write(
                    to: diffViewerPatchFileURL(for: fileURL),
                    atomically: true,
                    encoding: .utf8
                )
            }
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

    /// Writes the first paint without loading or hashing the web application.
    /// The host can register and open this document immediately, then navigate
    /// the same surface after the typed session document is ready.
    func writeDiffViewerOpeningHTML(
        to viewerURL: URL,
        title: String,
        message: String,
        appearance: DiffViewerAppearance
    ) throws {
        let escapedTitle = htmlEscaped(title)
        let escapedMessage = htmlEscaped(message)
        let html = """
        <!doctype html>
        <html data-cmux-diff-pending="true">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedTitle)</title>
          \(diffViewerPrepaintStyle(appearance: appearance))
          <style>
            body { margin: 0; color: var(--cmux-diff-fg); font: 13px -apple-system, BlinkMacSystemFont, sans-serif; }
            .loading { display: flex; align-items: center; gap: 10px; margin: 20px 16px; opacity: .72; }
            .spinner { width: 16px; height: 16px; border: 3px solid currentColor; border-right-color: transparent; border-radius: 50%; animation: spin .7s linear infinite; }
            .skeleton { margin: 38px 20px; display: grid; gap: 20px; opacity: .12; }
            .skeleton i { display: block; height: 14px; border-radius: 6px; background: currentColor; }
            .skeleton i:nth-child(2n) { width: 72%; }
            @keyframes spin { to { transform: rotate(360deg); } }
          </style>
        </head>
        <body>
          <div class="loading"><span class="spinner"></span><span>\(escapedMessage)</span></div>
          <div class="skeleton"><i></i><i></i><i></i><i></i><i></i><i></i></div>
        </body>
        </html>
        """
        try html.write(to: viewerURL, atomically: true, encoding: .utf8)
    }
}
