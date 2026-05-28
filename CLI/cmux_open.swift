import Darwin
import Foundation

struct CMUXAgentTurnDiffBaselineRecord: Codable {
    var workspaceId: String
    var surfaceId: String
    var sessionId: String
    var turnId: String?
    var agent: String
    var repoRoot: String
    var baseCommit: String
    var untrackedPaths: [String]?
    var untrackedPathHashes: [String: String]?
    var untrackedSnapshotId: String?
    var capturedAt: TimeInterval
}

struct CMUXAgentTurnDiffBaselineStore: Codable {
    var version: Int = 1
    var records: [CMUXAgentTurnDiffBaselineRecord] = []
}

private enum CMUXAgentTurnUntrackedSnapshotLimits {
    static let maxFiles = 64
    static let maxFileBytes: UInt64 = 1 * 1024 * 1024
    static let maxTotalBytes: UInt64 = 4 * 1024 * 1024
}

enum CMUXAgentTurnDiffBaselineFile {
    static func path(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let overrideDirectory = normalized(env["CMUX_AGENT_HOOK_STATE_DIR"]) {
            return URL(fileURLWithPath: homeExpandedPath(overrideDirectory, env: env), isDirectory: true)
                .appendingPathComponent("agent-turn-diff-baselines.json", isDirectory: false)
                .path
        }
        return homeExpandedPath("~/.cmuxterm/agent-turn-diff-baselines.json", env: env)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func homeExpandedPath(_ rawPath: String, env: [String: String]) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else {
            return trimmed
        }
        guard let home = normalized(env["HOME"]) else {
            return trimmed
        }
        if trimmed == "~" {
            return home
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: false)
            .path
    }
}

enum CMUXDiffViewerLocalization {
    static func string(
        _ key: String,
        defaultValue: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let bundle = localizationBundle()
        if let localization = explicitLocalization(in: environment, bundle: bundle),
           let localized = localizedString(key, defaultValue: defaultValue, bundle: bundle, localization: localization) {
            return localized
        }
        return bundle.localizedString(forKey: key, value: defaultValue, table: nil)
    }

    static func localizationBundle(
        mainBundle: Bundle = .main,
        executableURL: URL? = CLIExecutableLocator.currentExecutableURL()
    ) -> Bundle {
        CLIExecutableLocator.enclosingAppBundle(startingAt: executableURL) ?? mainBundle
    }

    private static func explicitLocalization(in environment: [String: String], bundle: Bundle) -> String? {
        guard let languages = appleLanguages(from: environment["AppleLanguages"]),
              !languages.isEmpty else {
            return nil
        }

        return Bundle.preferredLocalizations(
            from: bundle.localizations,
            forPreferences: languages
        ).first
    }

    private static func appleLanguages(from rawValue: String?) -> [String]? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("("), value.hasSuffix(")") {
            value.removeFirst()
            value.removeLast()
        }
        let languages = value
            .split(separator: ",")
            .map { piece in
                piece
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }
        return languages.isEmpty ? nil : languages
    }

    private static func localizedString(
        _ key: String,
        defaultValue: String,
        bundle: Bundle,
        localization: String
    ) -> String? {
        guard let lprojPath = bundle.path(forResource: localization, ofType: "lproj"),
              let languageBundle = Bundle(path: lprojPath) else {
            return nil
        }
        return languageBundle.localizedString(forKey: key, value: defaultValue, table: nil)
    }
}

extension CMUXCLI {
    private enum DiffViewerLimits {
        static let repoOptions = 4
        static let branchBaseOptions = 4
    }

    private struct OpenArguments {
        var workspace: String?
        var window: String?
        var surface: String?
        var pane: String?
        var focus: String?
        var noFocus = false
        var targets: [String] = []
    }

    private enum OpenTarget {
        case directory(String)
        case file(String)
        case url(String)
    }

    private struct DiffArguments {
        var workspace: String?
        var window: String?
        var surface: String?
        var focus: String?
        var noFocus = false
        var title: String?
        var layout: String?
        var fontSize: String?
        var cwd: String?
        var branchBase: String?
        var source: DiffSource?
        var inputs: [String] = []
    }

    private struct DiffInput {
        var patch: String
        var sourceLabel: String
        var defaultTitle: String
        var emptyMessage: String?
        var externalURL: String?
        var remotePatchURL: URL? = nil
    }

    private struct EmptyDiffSourceError: Error {
        var message: String
    }

    private struct DiffSourceContext {
        var workspaceId: String?
        var surfaceId: String?
        var repoRoot: String?
        var branchBaseRef: String?
    }

    private struct DiffViewerWriteResult {
        var fileURL: URL
        var url: URL
        var title: String
        var input: DiffInput
        var allowedFiles: [DiffViewerAllowedFile]
        var deferredSourceSet: DiffViewerDeferredSourceSet? = nil
    }

    private struct DiffViewerDeferredSourceSet {
        var pages: [DiffViewerDeferredSourcePage]
        var layout: String
        var appearance: DiffViewerAppearance
    }

    private struct DiffViewerDeferredSourcePage {
        var source: DiffSource
        var url: URL
        var titleOverride: String?
        var context: DiffSourceContext
        var sourceOptions: [DiffViewerSourceOption]
        var repoOptions: [DiffViewerSourceOption]
        var baseOptions: [DiffViewerSourceOption]
    }

    private struct DiffViewerRepoOption {
        var repoRoot: String
        var label: String
    }

    private struct DiffViewerBranchBaseOption {
        var ref: String
        var label: String
    }

    private struct DiffViewerSourceOption {
        var value: String
        var label: String
        var selected: Bool
        var url: String?
        var disabled: Bool
        var message: String?
        var sourceLabel: String?

        var jsonObject: [String: Any] {
            var object: [String: Any] = [
                "value": value,
                "label": label,
                "selected": selected,
                "disabled": disabled
            ]
            if let url { object["url"] = url }
            if let message { object["message"] = message }
            if let sourceLabel { object["sourceLabel"] = sourceLabel }
            return object
        }
    }

    private struct DiffViewerAssets {
        var diffsModuleURL: String
        var treesModuleURL: String
        var workerPoolModuleURL: String
        var workerModuleURL: String
        var files: [URL]
    }

    private struct DiffViewerAllowedFile: Codable {
        var requestPath: String
        var filePath: String
        var mimeType: String
        var remoteURL: String?

        enum CodingKeys: String, CodingKey {
            case requestPath = "request_path"
            case filePath = "file_path"
            case mimeType = "mime_type"
            case remoteURL = "remote_url"
        }

        var jsonObject: [String: Any] {
            var object: [String: Any] = [
                "request_path": requestPath,
                "file_path": filePath,
                "mime_type": mimeType
            ]
            if let remoteURL {
                object["remote_url"] = remoteURL
            }
            return object
        }
    }

    private struct DiffViewerURLMapper {
        static let scheme = "cmux-diff-viewer"
        static let sessionHistoryMarker = "cmux-diff-viewer"
        private static let requestPathAllowedCharacters: CharacterSet = {
            var characters = CharacterSet.urlPathAllowed
            characters.remove(charactersIn: "/?#%")
            return characters
        }()

        var token: String
        var rootDirectory: URL
        var origin: URL

        func viewerURL(for fileURL: URL) throws -> URL {
            guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
                throw CLIError(message: "Failed to build diff viewer URL")
            }
            components.percentEncodedPath = "/\(token)\(try requestPath(for: fileURL))"
            components.query = nil
            components.fragment = Self.sessionHistoryMarker
            guard let url = components.url else {
                throw CLIError(message: "Failed to build diff viewer URL")
            }
            return url
        }

        func allowedFile(fileURL: URL, mimeType: String) throws -> DiffViewerAllowedFile {
            DiffViewerAllowedFile(
                requestPath: try requestPath(for: fileURL),
                filePath: fileURL.standardizedFileURL.resolvingSymlinksInPath().path,
                mimeType: mimeType,
                remoteURL: nil
            )
        }

        func allowedRemotePatchFile(fileURL: URL, remoteURL: URL) throws -> DiffViewerAllowedFile {
            DiffViewerAllowedFile(
                requestPath: try requestPath(for: fileURL),
                filePath: "",
                mimeType: "text/x-diff",
                remoteURL: remoteURL.absoluteString
            )
        }

        private func requestPath(for fileURL: URL) throws -> String {
            let rootPath = rootDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(rootPath + "/") else {
                throw CLIError(message: "Diff viewer file is outside the viewer directory")
            }
            let relativePath = String(filePath.dropFirst(rootPath.count + 1))
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw CLIError(message: "Invalid diff viewer file path")
            }
            let encodedComponents = components.map { component in
                component.addingPercentEncoding(withAllowedCharacters: Self.requestPathAllowedCharacters) ?? component
            }
            return "/" + encodedComponents.joined(separator: "/")
        }
    }

    private struct DiffViewerHTTPManifest: Codable {
        var token: String
        var files: [DiffViewerAllowedFile]
    }

    private struct DiffViewerHTTPServerState: Codable {
        var port: Int
        var pid: Int32
        var rootPath: String
    }

    private static let diffViewerHTTPServerHealthResponse = Data("ok wait-v2 remote-stream\n".utf8)

    private struct DiffViewerLabels {
        var values: [String: String]

        subscript(_ key: String) -> String {
            values[key] ?? key
        }

        var jsonObject: [String: Any] {
            values
        }

        static func localized() -> DiffViewerLabels {
            DiffViewerLabels(values: [
                "additions": CMUXDiffViewerLocalization.string("diffViewer.additions", defaultValue: "Additions"),
                "bars": CMUXDiffViewerLocalization.string("diffViewer.bars", defaultValue: "Bars"),
                "changedFiles": CMUXDiffViewerLocalization.string("diffViewer.changedFiles", defaultValue: "Changed files"),
                "classic": CMUXDiffViewerLocalization.string("diffViewer.classic", defaultValue: "Classic"),
                "collapseAllDiffs": CMUXDiffViewerLocalization.string("diffViewer.collapseAllDiffs", defaultValue: "Collapse all diffs"),
                "collapseUnchangedContext": CMUXDiffViewerLocalization.string("diffViewer.collapseUnchangedContext", defaultValue: "Collapse unchanged context"),
                "copiedGitApplyCommand": CMUXDiffViewerLocalization.string("diffViewer.copiedGitApplyCommand", defaultValue: "Copied git apply command"),
                "copyGitApplyCommand": CMUXDiffViewerLocalization.string("diffViewer.copyGitApplyCommand", defaultValue: "Copy git apply command"),
                "deletions": CMUXDiffViewerLocalization.string("diffViewer.deletions", defaultValue: "Deletions"),
                "diffStats": CMUXDiffViewerLocalization.string("diffViewer.diffStats", defaultValue: "Diff stats"),
                "diffTarget": CMUXDiffViewerLocalization.string("diffViewer.diffTarget", defaultValue: "Diff target"),
                "diffViewer": CMUXDiffViewerLocalization.string("diffViewer.diffViewer", defaultValue: "Diff viewer"),
                "renderFailed": CMUXDiffViewerLocalization.string("diffViewer.renderFailed", defaultValue: "Could not render this diff. Check the patch input and try again."),
                "disableWordDiffs": CMUXDiffViewerLocalization.string("diffViewer.disableWordDiffs", defaultValue: "Disable word diffs"),
                "disableWordWrap": CMUXDiffViewerLocalization.string("diffViewer.disableWordWrap", defaultValue: "Disable word wrap"),
                "enableWordDiffs": CMUXDiffViewerLocalization.string("diffViewer.enableWordDiffs", defaultValue: "Enable word diffs"),
                "enableWordWrap": CMUXDiffViewerLocalization.string("diffViewer.enableWordWrap", defaultValue: "Enable word wrap"),
                "expandAllDiffs": CMUXDiffViewerLocalization.string("diffViewer.expandAllDiffs", defaultValue: "Expand all diffs"),
                "expandUnchangedContext": CMUXDiffViewerLocalization.string("diffViewer.expandUnchangedContext", defaultValue: "Expand unchanged context"),
                "files": CMUXDiffViewerLocalization.string("diffViewer.files", defaultValue: "Files"),
                "hideBackgrounds": CMUXDiffViewerLocalization.string("diffViewer.hideBackgrounds", defaultValue: "Hide backgrounds"),
                "hideFiles": CMUXDiffViewerLocalization.string("diffViewer.hideFiles", defaultValue: "Hide files"),
                "hideFileSearch": CMUXDiffViewerLocalization.string("diffViewer.hideFileSearch", defaultValue: "Hide file search"),
                "hideLineNumbers": CMUXDiffViewerLocalization.string("diffViewer.hideLineNumbers", defaultValue: "Hide line numbers"),
                "indicatorStyle": CMUXDiffViewerLocalization.string("diffViewer.indicatorStyle", defaultValue: "Indicator style"),
                "jumpToFile": CMUXDiffViewerLocalization.string("diffViewer.jumpToFile", defaultValue: "Jump to file"),
                "loadingDiff": CMUXDiffViewerLocalization.string("diffViewer.loadingDiff", defaultValue: "Loading diff..."),
                "loadingRenderer": CMUXDiffViewerLocalization.string("diffViewer.loadingRenderer", defaultValue: "Loading renderer..."),
                "noFileDiffs": CMUXDiffViewerLocalization.string("diffViewer.noFileDiffs", defaultValue: "No file diffs found in patch input."),
                "none": CMUXDiffViewerLocalization.string("diffViewer.none", defaultValue: "None"),
                "openSourceURL": CMUXDiffViewerLocalization.string("diffViewer.openSourceURL", defaultValue: "Open source URL"),
                "options": CMUXDiffViewerLocalization.string("diffViewer.options", defaultValue: "Options"),
                "parsingDiff": CMUXDiffViewerLocalization.string("diffViewer.parsingDiff", defaultValue: "Parsing diff..."),
                "refresh": CMUXDiffViewerLocalization.string("diffViewer.refresh", defaultValue: "Refresh"),
                "renderingDiff": CMUXDiffViewerLocalization.string("diffViewer.renderingDiff", defaultValue: "Rendering diff..."),
                "repoPath": CMUXDiffViewerLocalization.string("diffViewer.repoPath", defaultValue: "Repository path"),
                "branchBase": CMUXDiffViewerLocalization.string("diffViewer.branchBase", defaultValue: "Branch base"),
                "showBackgrounds": CMUXDiffViewerLocalization.string("diffViewer.showBackgrounds", defaultValue: "Show backgrounds"),
                "showFiles": CMUXDiffViewerLocalization.string("diffViewer.showFiles", defaultValue: "Show files"),
                "showFileSearch": CMUXDiffViewerLocalization.string("diffViewer.showFileSearch", defaultValue: "Show file search"),
                "showLineNumbers": CMUXDiffViewerLocalization.string("diffViewer.showLineNumbers", defaultValue: "Show line numbers"),
                "switchToSplitDiff": CMUXDiffViewerLocalization.string("diffViewer.switchToSplitDiff", defaultValue: "Switch to split diff"),
                "switchToUnifiedDiff": CMUXDiffViewerLocalization.string("diffViewer.switchToUnifiedDiff", defaultValue: "Switch to unified diff"),
                "untitled": CMUXDiffViewerLocalization.string("diffViewer.untitled", defaultValue: "Untitled"),
            ])
        }
    }

    private enum DiffSource: CaseIterable, Equatable {
        case unstaged
        case staged
        case branch
        case lastTurn

        init?(rawValue: String) {
            let normalized = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            switch normalized {
            case "unstaged", "worktree", "working-tree", "workingtree":
                self = .unstaged
            case "staged", "cached", "index":
                self = .staged
            case "branch":
                self = .branch
            case "last", "last-turn", "lastturn":
                self = .lastTurn
            default:
                return nil
            }
        }

        var optionName: String {
            switch self {
            case .unstaged: return "--unstaged"
            case .staged: return "--staged"
            case .branch: return "--branch"
            case .lastTurn: return "--last-turn"
            }
        }

        var slug: String {
            switch self {
            case .unstaged: return "unstaged"
            case .staged: return "staged"
            case .branch: return "branch"
            case .lastTurn: return "last-turn"
            }
        }

        var menuLabel: String {
            switch self {
            case .unstaged: return CMUXDiffViewerLocalization.string("diffViewer.source.unstaged", defaultValue: "Unstaged")
            case .staged: return CMUXDiffViewerLocalization.string("diffViewer.source.staged", defaultValue: "Staged")
            case .branch: return CMUXDiffViewerLocalization.string("diffViewer.source.branch", defaultValue: "Branch")
            case .lastTurn: return CMUXDiffViewerLocalization.string("diffViewer.source.lastTurn", defaultValue: "Last turn")
            }
        }

        var title: String {
            switch self {
            case .unstaged: return CMUXDiffViewerLocalization.string("diffViewer.title.unstagedChanges", defaultValue: "Unstaged changes")
            case .staged: return CMUXDiffViewerLocalization.string("diffViewer.title.stagedChanges", defaultValue: "Staged changes")
            case .branch: return CMUXDiffViewerLocalization.string("diffViewer.title.branchDiff", defaultValue: "Branch diff")
            case .lastTurn: return CMUXDiffViewerLocalization.string("diffViewer.title.lastTurnDiff", defaultValue: "Last turn diff")
            }
        }

        var emptyMessage: String {
            switch self {
            case .unstaged: return CMUXDiffViewerLocalization.string("diffViewer.empty.unstaged", defaultValue: "No unstaged changes to diff.")
            case .staged: return CMUXDiffViewerLocalization.string("diffViewer.empty.staged", defaultValue: "No staged changes to diff.")
            case .branch: return CMUXDiffViewerLocalization.string("diffViewer.empty.branch", defaultValue: "No branch changes to diff.")
            case .lastTurn: return CMUXDiffViewerLocalization.string("diffViewer.empty.lastTurn", defaultValue: "No last-turn changes to diff.")
            }
        }
    }

    private enum DiffViewerColorScheme {
        case light
        case dark
    }

    private struct DiffViewerAppearance {
        var fontFamily: String
        var fontSize: Double
        var lightTheme: DiffViewerTheme
        var darkTheme: DiffViewerTheme

        var lineHeight: Double {
            20
        }

        var diffHeaderHeight: Double {
            44
        }

        var jsonObject: [String: Any] {
            [
                "fontFamily": fontFamily,
                "fontSize": fontSize,
                "lineHeight": lineHeight,
                "diffHeaderHeight": diffHeaderHeight,
                "theme": [
                    "light": lightTheme.generatedName,
                    "dark": darkTheme.generatedName
                ],
                "themes": [
                    "light": lightTheme.jsonObject,
                    "dark": darkTheme.jsonObject
                ]
            ]
        }
    }

    private struct DiffViewerTheme {
        var generatedName: String
        var ghosttyName: String
        var type: String
        var background: String
        var foreground: String
        var selectionBackground: String
        var selectionForeground: String
        var palette: [Int: String]

        var jsonObject: [String: Any] {
            [
                "name": generatedName,
                "ghosttyName": ghosttyName,
                "type": type,
                "background": background,
                "foreground": foreground,
                "selectionBackground": selectionBackground,
                "selectionForeground": selectionForeground,
                "palette": Dictionary(uniqueKeysWithValues: palette.map { (String($0.key), $0.value) })
            ]
        }
    }

    func runOpenCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let parsedArgs = try parseOpenArguments(commandArgs)

        guard !parsedArgs.targets.isEmpty else {
            throw CLIError(message: "open requires at least one path or URL. Usage: cmux open <path-or-url>...")
        }

        let focus: Bool
        if parsedArgs.noFocus {
            focus = false
        } else if let focusOpt = parsedArgs.focus {
            guard let parsed = parseBoolString(focusOpt) else {
                throw CLIError(message: "--focus must be true|false")
            }
            focus = parsed
        } else {
            focus = true
        }

        let targets = try parsedArgs.targets.map(resolveOpenTarget)
        var fileCount = 0
        var urlCount = 0
        var directoryCount = 0

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let windowHandle = try normalizeWindowHandle(parsedArgs.window, client: client)
        let workspaceRaw = parsedArgs.workspace ?? (parsedArgs.window == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        let surfaceRaw = parsedArgs.surface ?? (parsedArgs.window == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle, windowHandle: windowHandle)
        let paneHandle = try normalizePaneHandle(parsedArgs.pane, client: client, workspaceHandle: workspaceHandle)

        var payloads: [[String: Any]] = []

        var pendingFiles: [String] = []
        func flushPendingFiles() throws {
            guard !pendingFiles.isEmpty else { return }
            let files = pendingFiles
            pendingFiles.removeAll()

            var params: [String: Any] = ["paths": files, "focus": focus]
            if let windowHandle { params["window_id"] = windowHandle }
            if let workspaceHandle { params["workspace_id"] = workspaceHandle }
            if let surfaceHandle { params["surface_id"] = surfaceHandle }
            if let paneHandle { params["pane_id"] = paneHandle }
            let payload = try client.sendV2(method: "file.open", params: params)
            payloads.append(["kind": "file", "payload": payload])
            fileCount += files.count
        }

        for target in targets {
            switch target {
            case .file(let path):
                pendingFiles.append(path)
            case .directory(let directory):
                try flushPendingFiles()
                var params: [String: Any] = ["cwd": directory]
                if let windowHandle { params["window_id"] = windowHandle }
                let payload = try client.sendV2(method: "workspace.create", params: params)
                payloads.append(["kind": "workspace", "payload": payload, "path": directory])
                directoryCount += 1
            case .url(let url):
                try flushPendingFiles()
                var params: [String: Any] = ["url": url, "focus": focus]
                if let windowHandle { params["window_id"] = windowHandle }
                if let workspaceHandle { params["workspace_id"] = workspaceHandle }
                if let surfaceHandle { params["surface_id"] = surfaceHandle }
                let payload = try client.sendV2(method: "browser.open_split", params: params)
                payloads.append(["kind": "url", "payload": payload, "url": url])
                urlCount += 1
            }
        }
        try flushPendingFiles()

        if jsonOutput {
            print(jsonString(formatIDs(["opened": payloads], mode: idFormat)))
            return
        }

        print(openCommandSummary(
            payloads: payloads,
            fileCount: fileCount,
            urlCount: urlCount,
            directoryCount: directoryCount,
            idFormat: idFormat
        ))
    }

    func runDiffCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let parsedArgs = try parseDiffArguments(commandArgs)
        guard parsedArgs.inputs.count <= 1 else {
            throw CLIError(message: "diff accepts at most one patch file. Usage: cmux diff [patch-file|-] [options]")
        }
        if parsedArgs.source != nil, !parsedArgs.inputs.isEmpty {
            throw CLIError(message: "diff accepts either a patch file or a git source, not both")
        }

        let focus: Bool
        if parsedArgs.noFocus {
            focus = false
        } else if let focusOpt = parsedArgs.focus {
            guard let parsed = parseBoolString(focusOpt) else {
                throw CLIError(message: "--focus must be true|false")
            }
            focus = parsed
        } else {
            focus = false
        }

        let layout = parsedArgs.layout ?? "split"
        guard layout == "split" || layout == "unified" else {
            throw CLIError(message: "--layout must be split|unified")
        }

        let fontSizeOverride: Double?
        if let rawFontSize = parsedArgs.fontSize {
            fontSizeOverride = try parseDiffViewerFontSize(rawFontSize)
        } else {
            fontSizeOverride = nil
        }

        var client: SocketClient?
        var didResolveTarget = false
        var windowHandle: String?
        var workspaceHandle: String?
        var surfaceHandle: String?
        defer { client?.close() }

        func connectedClient() throws -> SocketClient {
            if let client {
                return client
            }
            let newClient = try connectClient(
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                launchIfNeeded: true
            )
            client = newClient
            return newClient
        }

        func resolveTargetIfNeeded() throws {
            guard !didResolveTarget else { return }
            let activeClient = try connectedClient()
            windowHandle = try normalizeWindowHandle(parsedArgs.window, client: activeClient)
            let workspaceRaw = parsedArgs.workspace ?? (parsedArgs.window == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: activeClient, windowHandle: windowHandle)
            let surfaceRaw = parsedArgs.surface ?? (parsedArgs.window == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: activeClient, workspaceHandle: workspaceHandle, windowHandle: windowHandle)
            didResolveTarget = true
        }

        var diffSourceContext = DiffSourceContext(
            workspaceId: nil,
            surfaceId: nil,
            repoRoot: nil,
            branchBaseRef: parsedArgs.branchBase
        )
        if let cwd = parsedArgs.cwd {
            diffSourceContext.repoRoot = try gitRepoRoot(startingAt: resolvePath(cwd))
        }
        if parsedArgs.source != nil {
            try resolveTargetIfNeeded()
            var sourceContext = try canonicalDiffSourceContext(
                workspaceHandle: workspaceHandle,
                surfaceHandle: surfaceHandle,
                windowHandle: windowHandle,
                client: try connectedClient()
            )
            sourceContext.repoRoot = diffSourceContext.repoRoot
            sourceContext.branchBaseRef = diffSourceContext.branchBaseRef
            diffSourceContext = sourceContext
            workspaceHandle = sourceContext.workspaceId ?? workspaceHandle
            surfaceHandle = sourceContext.surfaceId ?? surfaceHandle
        }

        let appearance = diffViewerAppearance(
            socketPath: socketPath,
            fontSizeOverride: fontSizeOverride
        )
        let viewer = try writeDiffViewer(
            rawInput: parsedArgs.inputs.first,
            source: parsedArgs.source,
            titleOverride: parsedArgs.title,
            layout: layout,
            appearance: appearance,
            context: diffSourceContext
        )

        try resolveTargetIfNeeded()
        let activeClient = try connectedClient()

        var params: [String: Any] = [
            "url": viewer.url.absoluteString,
            "focus": focus,
            "show_omnibar": false,
            "bypass_remote_proxy": true
        ]
        if viewer.url.scheme == DiffViewerURLMapper.scheme {
            params["diff_viewer_token"] = viewer.url.host ?? ""
            params["diff_viewer_files"] = viewer.allowedFiles.map(\.jsonObject)
        }
        if let windowHandle { params["window_id"] = windowHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let surfaceHandle { params["surface_id"] = surfaceHandle }

        let payload = try activeClient.sendV2(method: "browser.open_split", params: params)

        if jsonOutput {
            var response = payload
            response["path"] = viewer.fileURL.path
            response["url"] = viewer.url.absoluteString
            response["title"] = viewer.title
            response["source"] = viewer.input.sourceLabel
            print(jsonString(formatIDs(response, mode: idFormat)))
            completeDeferredDiffViewerSources(viewer.deferredSourceSet)
            return
        }

        let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
        let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
        print("OK surface=\(surfaceText) pane=\(paneText) path=\(viewer.fileURL.path)")
        completeDeferredDiffViewerSources(viewer.deferredSourceSet)
    }

    private func canonicalDiffSourceContext(
        workspaceHandle: String?,
        surfaceHandle: String?,
        windowHandle: String?,
        client: SocketClient
    ) throws -> DiffSourceContext {
        let workspaceId = try canonicalDiffWorkspaceId(
            workspaceHandle,
            windowHandle: windowHandle,
            client: client
        )
        let surfaceId = try canonicalDiffSurfaceId(
            surfaceHandle,
            workspaceId: workspaceId,
            windowHandle: windowHandle,
            client: client
        )
        return DiffSourceContext(workspaceId: workspaceId, surfaceId: surfaceId, repoRoot: nil, branchBaseRef: nil)
    }

    private func canonicalDiffWorkspaceId(
        _ workspaceHandle: String?,
        windowHandle: String?,
        client: SocketClient
    ) throws -> String? {
        guard let workspaceHandle = normalizedDiffSourceValue(workspaceHandle) else {
            return nil
        }
        if UUID(uuidString: workspaceHandle) != nil {
            return workspaceHandle
        }

        var params: [String: Any] = [:]
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        if let matched = try matchingDiffWorkspaceId(workspaceHandle, params: params, client: client) {
            return matched
        }

        if windowHandle == nil {
            let listed = try client.sendV2(method: "window.list")
            let windows = listed["windows"] as? [[String: Any]] ?? []
            for window in windows {
                guard let listedWindowHandle = (window["id"] as? String) ?? (window["ref"] as? String) else {
                    continue
                }
                if let matched = try matchingDiffWorkspaceId(
                    workspaceHandle,
                    params: ["window_id": listedWindowHandle],
                    client: client
                ) {
                    return matched
                }
            }
        }

        throw CLIError(message: "Workspace not found: \(workspaceHandle)")
    }

    private func canonicalDiffSurfaceId(
        _ surfaceHandle: String?,
        workspaceId: String?,
        windowHandle: String?,
        client: SocketClient
    ) throws -> String? {
        guard let surfaceHandle = normalizedDiffSourceValue(surfaceHandle) else {
            return nil
        }
        if UUID(uuidString: surfaceHandle) != nil {
            return surfaceHandle
        }

        var params: [String: Any] = [:]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        let listed = try client.sendV2(method: "surface.list", params: params)
        let surfaces = listed["surfaces"] as? [[String: Any]] ?? []
        for surface in surfaces where diffHandle(surfaceHandle, matches: surface) {
            return (surface["id"] as? String) ?? (surface["ref"] as? String) ?? surfaceHandle
        }
        throw CLIError(message: "Surface not found: \(surfaceHandle)")
    }

    private func matchingDiffWorkspaceId(
        _ workspaceHandle: String,
        params: [String: Any],
        client: SocketClient
    ) throws -> String? {
        let listed = try client.sendV2(method: "workspace.list", params: params)
        let workspaces = listed["workspaces"] as? [[String: Any]] ?? []
        for workspace in workspaces where diffHandle(workspaceHandle, matches: workspace) {
            return (workspace["id"] as? String) ?? (workspace["ref"] as? String) ?? workspaceHandle
        }
        return nil
    }

    private func diffHandle(_ handle: String, matches item: [String: Any]) -> Bool {
        guard let target = normalizedDiffSourceValue(handle) else {
            return false
        }
        for candidate in [item["id"] as? String, item["ref"] as? String] {
            guard let candidate = normalizedDiffSourceValue(candidate) else {
                continue
            }
            if let targetUUID = UUID(uuidString: target),
               let candidateUUID = UUID(uuidString: candidate) {
                if targetUUID == candidateUUID {
                    return true
                }
            } else if target.lowercased() == candidate.lowercased() {
                return true
            }
        }
        return false
    }

    private func parseOpenArguments(_ commandArgs: [String]) throws -> OpenArguments {
        var parsed = OpenArguments()
        var index = 0
        var isParsingOptions = true

        while index < commandArgs.count {
            let arg = commandArgs[index]
            if isParsingOptions, arg == "--" {
                isParsingOptions = false
                index += 1
                continue
            }

            if isParsingOptions {
                switch arg {
                case "--workspace":
                    parsed.workspace = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--window":
                    parsed.window = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--surface":
                    parsed.surface = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--pane":
                    parsed.pane = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--focus":
                    parsed.focus = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--no-focus":
                    parsed.noFocus = true
                    index += 1
                    continue
                default:
                    if arg.hasPrefix("-") {
                        throw CLIError(message: "open: unknown flag '\(arg)'. Usage: cmux open <path-or-url>... [--workspace <id|ref|index>] [--surface <id|ref|index>] [--pane <id|ref|index>] [--window <id|ref|index>] [--focus true|false] [--no-focus]")
                    }
                }
            }

            parsed.targets.append(arg)
            index += 1
        }

        return parsed
    }

    private func parseDiffArguments(_ commandArgs: [String]) throws -> DiffArguments {
        var parsed = DiffArguments()
        var index = 0
        var isParsingOptions = true

        while index < commandArgs.count {
            let arg = commandArgs[index]
            if isParsingOptions, arg == "--" {
                isParsingOptions = false
                index += 1
                continue
            }

            if isParsingOptions {
                switch arg {
                case "--workspace":
                    parsed.workspace = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--window":
                    parsed.window = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--surface":
                    parsed.surface = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--focus":
                    parsed.focus = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--no-focus":
                    parsed.noFocus = true
                    index += 1
                    continue
                case "--title":
                    parsed.title = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--layout":
                    parsed.layout = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--font-size":
                    parsed.fontSize = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--cwd", "--repo", "--path":
                    parsed.cwd = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--base", "--branch-base":
                    parsed.branchBase = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--source":
                    let rawSource = try openOptionValue(commandArgs, index: index, name: arg)
                    guard let source = DiffSource(rawValue: rawSource) else {
                        throw CLIError(message: "Unknown diff source '\(rawSource)'. Expected unstaged, staged, branch, or last-turn.")
                    }
                    try setDiffSource(source, parsed: &parsed)
                    index += 2
                    continue
                case "--unstaged":
                    try setDiffSource(.unstaged, parsed: &parsed)
                    index += 1
                    continue
                case "--staged":
                    try setDiffSource(.staged, parsed: &parsed)
                    index += 1
                    continue
                case "--branch":
                    try setDiffSource(.branch, parsed: &parsed)
                    index += 1
                    continue
                case "--last-turn":
                    try setDiffSource(.lastTurn, parsed: &parsed)
                    index += 1
                    continue
                default:
                    if arg.hasPrefix("-"), arg != "-" {
                        throw CLIError(message: "diff: unknown flag '\(arg)'. Usage: cmux diff [patch-file|-] [--source <unstaged|staged|branch|last-turn>] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--cwd <path>] [--base <ref>] [--focus true|false] [--no-focus] [--title <text>] [--layout split|unified] [--font-size <points>]")
                    }
                }
            }

            parsed.inputs.append(arg)
            index += 1
        }

        return parsed
    }

    private func setDiffSource(_ source: DiffSource, parsed: inout DiffArguments) throws {
        if let existing = parsed.source, existing != source {
            throw CLIError(message: "diff accepts only one source, got \(existing.optionName) and \(source.optionName)")
        }
        parsed.source = source
    }

    private func openOptionValue(_ args: [String], index: Int, name: String) throws -> String {
        guard index + 1 < args.count else {
            throw CLIError(message: "\(name) requires a value")
        }
        return args[index + 1]
    }

    private func parseDiffViewerFontSize(_ rawValue: String) throws -> Double {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(trimmed),
              isUsableDiffViewerFontSize(size) else {
            throw CLIError(message: "--font-size must be a positive number no larger than 96")
        }
        return roundedDiffViewerMetric(size)
    }

    private func resolveOpenTarget(_ raw: String) throws -> OpenTarget {
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .url(url.absoluteString)
        }

        let resolved = resolvePath(raw)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }

        if isDir.boolValue {
            return .directory(resolved)
        }
        return .file(resolved)
    }

    private func readDiffInput(
        _ rawInput: String?,
        source: DiffSource?,
        context: DiffSourceContext
    ) throws -> DiffInput {
        if let source {
            return try readGitDiffInput(source: source, context: context)
        }

        guard let rawInput, rawInput != "-" else {
            guard isatty(STDIN_FILENO) == 0 else {
                throw CLIError(message: "diff requires a patch file, piped stdin, or a git source. Usage: cmux diff <patch-file>|-|--unstaged|--staged|--branch|--last-turn")
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return DiffInput(
                patch: try decodeDiffData(data, sourceDescription: "stdin"),
                sourceLabel: "stdin",
                defaultTitle: "cmux diff",
                emptyMessage: nil,
                externalURL: nil
            )
        }

        if let trustedRemoteURL = diffInputTrustedRemotePatchURL(rawInput) {
            let sourceURL = URL(string: rawInput) ?? trustedRemoteURL
            if diffViewerShouldStreamRemotePatch() {
                return DiffInput(
                    patch: "",
                    sourceLabel: sourceURL.absoluteString,
                    defaultTitle: diffInputURLTitle(sourceURL),
                    emptyMessage: nil,
                    externalURL: diffInputExternalURL(sourceURL).absoluteString,
                    remotePatchURL: trustedRemoteURL
                )
            }
            do {
                return DiffInput(
                    patch: try fetchDiffURL(trustedRemoteURL),
                    sourceLabel: sourceURL.absoluteString,
                    defaultTitle: diffInputURLTitle(sourceURL),
                    emptyMessage: nil,
                    externalURL: diffInputExternalURL(sourceURL).absoluteString
                )
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError(message: "Failed to fetch diff URL: \(trustedRemoteURL.absoluteString)")
            }
        }

        if let url = diffInputPatchURL(rawInput) {
            let sourceURL = URL(string: rawInput) ?? url
            do {
                return DiffInput(
                    patch: try fetchDiffURL(url),
                    sourceLabel: sourceURL.absoluteString,
                    defaultTitle: diffInputURLTitle(sourceURL),
                    emptyMessage: nil,
                    externalURL: diffInputExternalURL(sourceURL).absoluteString
                )
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError(message: "Failed to fetch diff URL: \(url.absoluteString)")
            }
        }

        let resolved = resolvePath(rawInput)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }
        guard !isDir.boolValue else {
            throw CLIError(message: "Path is a directory, not a patch file: \(resolved)")
        }
        guard FileManager.default.isReadableFile(atPath: resolved) else {
            throw CLIError(message: "File not readable: \(resolved)")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let filename = URL(fileURLWithPath: resolved).lastPathComponent
        return DiffInput(
            patch: try decodeDiffData(data, sourceDescription: resolved),
            sourceLabel: resolved,
            defaultTitle: filename.isEmpty ? "cmux diff" : filename,
            emptyMessage: nil,
            externalURL: nil
        )
    }

    private func diffViewerShouldStreamRemotePatch() -> Bool {
        let value = ProcessInfo.processInfo.environment["CMUX_DIFF_VIEWER_STREAM_REMOTE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    private func readGitDiffInput(source: DiffSource, context: DiffSourceContext) throws -> DiffInput {
        let repoRoot = try gitRepoRootForDiff(context)
        let patch: String
        let sourceLabel: String
        switch source {
        case .unstaged:
            patch = try gitStdout(gitDiffPatchArguments(["--"]), in: repoRoot)
            sourceLabel = "git unstaged"
        case .staged:
            patch = try gitStdout(gitDiffPatchArguments(["--cached", "--"]), in: repoRoot)
            sourceLabel = "git staged"
        case .branch:
            let baseRef = try resolvedGitBranchDiffBaseRef(context.branchBaseRef, in: repoRoot)
            let mergeBase = try gitSingleLine(["merge-base", "HEAD", baseRef], in: repoRoot)
            patch = try gitStdout(gitDiffPatchArguments([mergeBase, "--"]), in: repoRoot)
            sourceLabel = "git branch \(baseRef)"
        case .lastTurn:
            guard let workspaceId = normalizedDiffSourceValue(context.workspaceId),
                  let surfaceId = normalizedDiffSourceValue(context.surfaceId) else {
                throw CLIError(message: "cmux diff --last-turn requires a workspace and surface context. Run it from a cmux terminal or pass --workspace and --surface.")
            }
            let env = ProcessInfo.processInfo.environment
            let baselineStorePath = CMUXAgentTurnDiffBaselineFile.path(env: env)
            let record = try latestAgentTurnDiffBaseline(
                repoRoot: repoRoot,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                env: env
            )
            _ = try gitStdout(["cat-file", "-e", "\(record.baseCommit)^{tree}"], in: repoRoot)
            patch = try joinedGitDiffPatches([
                gitStdout(gitDiffPatchArguments([record.baseCommit, "--"]), in: repoRoot),
                gitUntrackedPatchSinceBaseline(record: record, in: repoRoot, storePath: baselineStorePath)
            ])
            sourceLabel = "git last-turn \(workspaceId) \(surfaceId)"
        }
        return DiffInput(
            patch: patch,
            sourceLabel: sourceLabel,
            defaultTitle: source.title,
            emptyMessage: source.emptyMessage,
            externalURL: nil
        )
    }

    private func diffInputPatchURL(_ rawInput: String) -> URL? {
        guard let url = URL(string: rawInput),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else {
            return nil
        }

        if host == "diffshub.com" || host == "www.diffshub.com" {
            let components = url.pathComponents
            if components.count >= 5,
               components[3] == "pull",
               Int(components[4]) != nil {
                return URL(string: "https://github.com/\(components[1])/\(components[2])/pull/\(components[4]).diff")
            }
        }

        if host == "github.com" || host == "www.github.com" {
            let components = url.pathComponents
            if components.count >= 5,
               components[3] == "pull",
               Int(components[4].replacingOccurrences(of: ".patch", with: "").replacingOccurrences(of: ".diff", with: "")) != nil {
                let pullComponent = components[4]
                if pullComponent.hasSuffix(".patch") || pullComponent.hasSuffix(".diff") {
                    return url
                }
                return URL(string: "https://github.com/\(components[1])/\(components[2])/pull/\(pullComponent).diff")
            }
        }

        return url
    }

    private func diffInputTrustedRemotePatchURL(_ rawInput: String) -> URL? {
        guard let url = URL(string: rawInput),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased() else {
            return nil
        }

        if host == "diffshub.com" || host == "www.diffshub.com" {
            let components = url.pathComponents
            guard components.count >= 5,
                  components[3] == "pull" else {
                return nil
            }
            return trustedGitHubPullPatchURL(
                owner: components[1],
                repo: components[2],
                pullComponent: components[4],
                defaultExtension: "diff"
            )
        }

        if host == "github.com" || host == "www.github.com" {
            let components = url.pathComponents
            guard components.count >= 5,
                  components[3] == "pull" else {
                return nil
            }
            return trustedGitHubPullPatchURL(
                owner: components[1],
                repo: components[2],
                pullComponent: components[4],
                defaultExtension: "diff"
            )
        }

        return nil
    }

    private func trustedGitHubPullPatchURL(
        owner: String,
        repo: String,
        pullComponent: String,
        defaultExtension: String
    ) -> URL? {
        guard githubPathSegmentIsSafe(owner),
              githubPathSegmentIsSafe(repo) else {
            return nil
        }

        let suffix: String
        let pullNumber: String
        if pullComponent.hasSuffix(".patch") {
            suffix = "patch"
            pullNumber = String(pullComponent.dropLast(".patch".count))
        } else if pullComponent.hasSuffix(".diff") {
            suffix = "diff"
            pullNumber = String(pullComponent.dropLast(".diff".count))
        } else {
            suffix = defaultExtension
            pullNumber = pullComponent
        }
        guard suffix == "diff" || suffix == "patch",
              pullNumber.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              Int(pullNumber).map({ $0 > 0 }) == true else {
            return nil
        }
        return URL(string: "https://github.com/\(owner)/\(repo)/pull/\(pullNumber).\(suffix)")
    }

    private func githubPathSegmentIsSafe(_ component: String) -> Bool {
        guard !component.isEmpty else { return false }
        return component.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 65 && scalar.value <= 90) ||
                (scalar.value >= 97 && scalar.value <= 122) ||
                scalar == "-" ||
                scalar == "_" ||
                scalar == "."
        }
    }

    private func diffInputExternalURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return url
        }
        var components = url.pathComponents
        guard components.count >= 5,
              components[3] == "pull" else {
            return url
        }
        components[4] = components[4]
            .replacingOccurrences(of: ".patch", with: "")
            .replacingOccurrences(of: ".diff", with: "")
        var normalized = URLComponents(url: url, resolvingAgainstBaseURL: false)
        normalized?.path = components.joined(separator: "/").replacingOccurrences(of: "//", with: "/")
        normalized?.query = nil
        normalized?.fragment = nil
        return normalized?.url ?? url
    }

    private func fetchDiffURL(_ url: URL) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "curl",
                "-fL",
                "--silent",
                "--show-error",
                "--max-time", "120",
                url.absoluteString
            ],
            timeout: 130
        )
        if result.timedOut {
            throw CLIError(message: "Timed out fetching diff URL: \(url.absoluteString)")
        }
        guard result.status == 0 else {
            throw CLIError(message: "Failed to fetch diff URL: \(url.absoluteString)")
        }
        return result.stdout
    }

    private func diffInputURLTitle(_ url: URL) -> String {
        let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty {
            return last
        }
        return url.host ?? "cmux diff"
    }

    private func decodeDiffData(_ data: Data, sourceDescription: String) throws -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .ascii) {
            return text
        }
        throw CLIError(message: "Diff input is not valid UTF-8: \(sourceDescription)")
    }

    private func currentGitRepoRoot() throws -> String {
        try gitRepoRoot(startingAt: FileManager.default.currentDirectoryPath)
    }

    private func gitRepoRootForDiff(_ context: DiffSourceContext) throws -> String {
        guard let repoRoot = context.repoRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repoRoot.isEmpty else {
            return try currentGitRepoRoot()
        }
        return try gitRepoRoot(startingAt: repoRoot)
    }

    private func gitRepoRoot(startingAt directory: String) throws -> String {
        do {
            return try standardizedDiffSourcePath(gitSingleLine(["rev-parse", "--show-toplevel"], in: directory))
        } catch {
            throw CLIError(message: "cmux diff git sources require a git repository")
        }
    }

    private func gitBranchDiffBaseRef(in repoRoot: String) throws -> String {
        if let originHead = try? gitSingleLine(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repoRoot),
           !originHead.isEmpty {
            return originHead
        }
        for candidate in ["origin/main", "origin/master", "upstream/main", "upstream/master", "main", "master"] {
            if (try? gitStdout(["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"], in: repoRoot)) != nil {
                return candidate
            }
        }
        if let upstream = try? gitSingleLine(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: repoRoot),
           !upstream.isEmpty {
            return upstream
        }
        throw CLIError(message: "Unable to find a branch diff base. Set an upstream branch or create origin/main.")
    }

    private func resolvedGitBranchDiffBaseRef(_ rawBaseRef: String?, in repoRoot: String) throws -> String {
        guard let rawBaseRef,
              !rawBaseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try gitBranchDiffBaseRef(in: repoRoot)
        }
        let baseRef = rawBaseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? gitStdout(["rev-parse", "--verify", "--quiet", "\(baseRef)^{commit}"], in: repoRoot)) != nil else {
            throw CLIError(message: "Branch diff base not found in repository: \(baseRef)")
        }
        return baseRef
    }

    private func gitSingleLine(_ arguments: [String], in directory: String) throws -> String {
        let output = try gitStdout(arguments, in: directory)
        guard let line = output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !line.isEmpty else {
            throw CLIError(message: "git returned empty output for \(arguments.joined(separator: " "))")
        }
        return line
    }

    private func gitStdout(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = 60
    ) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory] + arguments,
            timeout: timeout
        )
        if result.timedOut {
            throw CLIError(message: "git \(arguments.joined(separator: " ")) timed out")
        }
        guard result.status == 0 else {
            let command = (["git"] + arguments).joined(separator: " ")
            throw CLIError(message: "\(command) failed with status \(result.status)")
        }
        return result.stdout
    }

    private func gitDiffPatchArguments(_ tail: [String]) -> [String] {
        ["diff", "--no-ext-diff", "--no-color", "--binary"] + tail
    }

    private func gitStdout(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = 60,
        allowedExitStatuses: Set<Int32>
    ) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory] + arguments,
            timeout: timeout
        )
        if result.timedOut {
            throw CLIError(message: "git \(arguments.joined(separator: " ")) timed out")
        }
        guard allowedExitStatuses.contains(result.status) else {
            let command = (["git"] + arguments).joined(separator: " ")
            throw CLIError(message: "\(command) failed with status \(result.status)")
        }
        return result.stdout
    }

    private func gitStdoutData(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = 60,
        allowedExitStatuses: Set<Int32> = [0]
    ) throws -> Data {
        let result = CLIProcessRunner.runProcessData(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory] + arguments,
            timeout: timeout
        )
        if result.timedOut {
            throw CLIError(message: "git \(arguments.joined(separator: " ")) timed out")
        }
        guard allowedExitStatuses.contains(result.status) else {
            let command = (["git"] + arguments).joined(separator: " ")
            throw CLIError(message: "\(command) failed with status \(result.status)")
        }
        return result.stdout
    }

    private func gitUntrackedPaths(in repoRoot: String) throws -> [String] {
        let output = try gitStdout(["ls-files", "--others", "--exclude-standard", "-z"], in: repoRoot)
        return output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    private func gitUntrackedPatchSinceBaseline(
        record: CMUXAgentTurnDiffBaselineRecord,
        in repoRoot: String,
        storePath: String
    ) throws -> String {
        let baselinePaths = Set(record.untrackedPaths ?? [])
        let baselineHashes = record.untrackedPathHashes ?? [:]
        let currentPaths = try gitUntrackedPaths(in: repoRoot)
        let currentPathSet = Set(currentPaths)
        var patches: [String] = []
        for path in currentPaths {
            guard baselinePaths.contains(path) else {
                patches.append(try gitAddedUntrackedPatch(path: path, in: repoRoot))
                continue
            }
            guard let baselineHash = baselineHashes[path] else {
                continue
            }
            guard try gitUntrackedPathHash(path, in: repoRoot) != baselineHash else {
                continue
            }
            if let baselineFileURL = agentTurnDiffBaselineSnapshotFileURL(
                path: path,
                record: record,
                storePath: storePath
            ), let patch = try gitChangedUntrackedPatch(path: path, baselineFileURL: baselineFileURL, in: repoRoot) {
                patches.append(patch)
            } else if let patch = try gitChangedUntrackedPatchFromGitObject(
                path: path,
                baselineHash: baselineHash,
                in: repoRoot
            ) {
                patches.append(patch)
            }
        }
        for path in baselinePaths.subtracting(currentPathSet).sorted() {
            guard !repoPathExists(path, in: repoRoot) else {
                continue
            }
            guard let baselineHash = baselineHashes[path] else {
                continue
            }
            let patch: String?
            if let baselineFileURL = agentTurnDiffBaselineSnapshotFileURL(
                path: path,
                record: record,
                storePath: storePath
            ) {
                patch = try gitDeletedUntrackedPatch(path: path, baselineFileURL: baselineFileURL)
            } else {
                patch = try gitDeletedUntrackedPatchFromGitObject(path: path, baselineHash: baselineHash, in: repoRoot)
            }
            guard let patch else { continue }
            patches.append(patch)
        }
        return joinedGitDiffPatches(patches)
    }

    private func gitAddedUntrackedPatch(path: String, in repoRoot: String) throws -> String {
        try gitStdout(
            gitDiffPatchArguments(["--no-index", "--", "/dev/null", path]),
            in: repoRoot,
            allowedExitStatuses: [0, 1]
        )
    }

    private func gitChangedUntrackedPatch(
        path: String,
        baselineFileURL: URL,
        in repoRoot: String
    ) throws -> String? {
        guard let tempPathURL = safeTemporaryGitPathURL(relativePath: path) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: baselineFileURL.path) else {
            return nil
        }

        let tempRoot = tempPathURL.root
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let baselineFile = tempRoot
            .appendingPathComponent("baseline", isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        let currentFile = tempRoot
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: baselineFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: currentFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: baselineFileURL, to: baselineFile)
        guard let currentURL = safeRepoPathURL(relativePath: path, repoRoot: repoRoot) else {
            return nil
        }
        try FileManager.default.copyItem(
            at: currentURL,
            to: currentFile
        )

        let patch = try gitStdout(
            gitDiffPatchArguments(["--no-index", "--", "baseline/\(path)", "current/\(path)"]),
            in: tempRoot.path,
            allowedExitStatuses: [0, 1]
        )
        return rewriteChangedUntrackedPatch(patch)
    }

    private func gitChangedUntrackedPatchFromGitObject(
        path: String,
        baselineHash: String,
        in repoRoot: String
    ) throws -> String? {
        guard let tempPathURL = safeTemporaryGitPathURL(relativePath: path) else {
            return nil
        }
        let objectCheck = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", repoRoot, "cat-file", "-e", "\(baselineHash)^{blob}"],
            timeout: 30
        )
        guard !objectCheck.timedOut, objectCheck.status == 0 else {
            return nil
        }

        let tempRoot = tempPathURL.root
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let baselineFile = tempRoot
            .appendingPathComponent("baseline", isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        let currentFile = tempRoot
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: baselineFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: currentFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let baselineContent = try gitStdoutData(["cat-file", "blob", baselineHash], in: repoRoot)
        try baselineContent.write(to: baselineFile, options: .atomic)
        guard let currentURL = safeRepoPathURL(relativePath: path, repoRoot: repoRoot) else {
            return nil
        }
        try FileManager.default.copyItem(
            at: currentURL,
            to: currentFile
        )

        let patch = try gitStdout(
            gitDiffPatchArguments(["--no-index", "--", "baseline/\(path)", "current/\(path)"]),
            in: tempRoot.path,
            allowedExitStatuses: [0, 1]
        )
        return rewriteChangedUntrackedPatch(patch)
    }

    private func gitDeletedUntrackedPatch(
        path: String,
        baselineFileURL: URL
    ) throws -> String? {
        guard let tempPathURL = safeTemporaryGitPathURL(relativePath: path) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: baselineFileURL.path) else {
            return nil
        }

        let tempRoot = tempPathURL.root
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(
            at: tempPathURL.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: baselineFileURL, to: tempPathURL.file)
        return try gitStdout(
            gitDiffPatchArguments(["--no-index", "--", path, "/dev/null"]),
            in: tempRoot.path,
            allowedExitStatuses: [0, 1]
        )
    }

    private func gitDeletedUntrackedPatchFromGitObject(
        path: String,
        baselineHash: String,
        in repoRoot: String
    ) throws -> String? {
        guard let tempPathURL = safeTemporaryGitPathURL(relativePath: path) else {
            return nil
        }
        let objectCheck = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", repoRoot, "cat-file", "-e", "\(baselineHash)^{blob}"],
            timeout: 30
        )
        guard !objectCheck.timedOut, objectCheck.status == 0 else {
            return nil
        }

        let tempRoot = tempPathURL.root
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(
            at: tempPathURL.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let content = try gitStdoutData(["cat-file", "blob", baselineHash], in: repoRoot)
        try content.write(to: tempPathURL.file, options: .atomic)
        return try gitStdout(
            gitDiffPatchArguments(["--no-index", "--", path, "/dev/null"]),
            in: tempRoot.path,
            allowedExitStatuses: [0, 1]
        )
    }

    private func rewriteChangedUntrackedPatch(_ patch: String) -> String {
        patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                var line = String(rawLine)
                if line.hasPrefix("diff --git ") {
                    replaceFirstOccurrence(in: &line, of: "a/baseline/", with: "a/")
                    replaceFirstOccurrence(in: &line, of: "b/current/", with: "b/")
                } else if line.hasPrefix("--- ") {
                    replaceFirstOccurrence(in: &line, of: "a/baseline/", with: "a/")
                } else if line.hasPrefix("+++ ") {
                    replaceFirstOccurrence(in: &line, of: "b/current/", with: "b/")
                }
                return line
            }
            .joined(separator: "\n")
    }

    private func replaceFirstOccurrence(in line: inout String, of target: String, with replacement: String) {
        guard let range = line.range(of: target) else { return }
        line.replaceSubrange(range, with: replacement)
    }

    private func safeTemporaryGitPathURL(relativePath: String) -> (root: URL, file: URL)? {
        guard let components = safeRelativePathComponents(relativePath) else {
            return nil
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diff-untracked-\(UUID().uuidString)", isDirectory: true)
        let file = components.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
        return (root, file)
    }

    private func repoPathExists(_ relativePath: String, in repoRoot: String) -> Bool {
        guard let url = safeRepoPathURL(relativePath: relativePath, repoRoot: repoRoot) else {
            return true
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func safeRepoPathURL(relativePath: String, repoRoot: String) -> URL? {
        guard let components = safeRelativePathComponents(relativePath) else {
            return nil
        }
        let root = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let url = components
            .reduce(root) { partial, component in
                partial.appendingPathComponent(component, isDirectory: false)
            }
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else {
            return nil
        }
        return url
    }

    private func safeRelativePathComponents(_ relativePath: String) -> [String]? {
        guard !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components
    }

    private func agentTurnDiffBaselineSnapshotRootURL(storePath: String) -> URL {
        URL(fileURLWithPath: storePath)
            .deletingLastPathComponent()
            .appendingPathComponent("agent-turn-diff-baseline-snapshots", isDirectory: true)
    }

    private func agentTurnDiffBaselineSnapshotStagingRootURL(storePath: String) -> URL {
        URL(fileURLWithPath: storePath)
            .deletingLastPathComponent()
            .appendingPathComponent("agent-turn-diff-baseline-snapshots-staging", isDirectory: true)
    }

    private func agentTurnDiffBaselineSnapshotDirectoryURL(
        snapshotId: String,
        storePath: String
    ) -> URL? {
        guard snapshotId.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return agentTurnDiffBaselineSnapshotRootURL(storePath: storePath)
            .appendingPathComponent(snapshotId, isDirectory: true)
    }

    private func agentTurnDiffBaselineStagedSnapshotDirectoryURL(
        snapshotId: String,
        storePath: String
    ) -> URL? {
        guard snapshotId.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return agentTurnDiffBaselineSnapshotStagingRootURL(storePath: storePath)
            .appendingPathComponent(snapshotId, isDirectory: true)
    }

    private func agentTurnDiffBaselineSnapshotFileURL(
        path: String,
        record: CMUXAgentTurnDiffBaselineRecord,
        storePath: String
    ) -> URL? {
        guard let snapshotId = record.untrackedSnapshotId,
              let snapshotDirectory = agentTurnDiffBaselineSnapshotDirectoryURL(
                snapshotId: snapshotId,
                storePath: storePath
              ),
              let components = safeRelativePathComponents(path) else {
            return nil
        }
        let filesRoot = snapshotDirectory.appendingPathComponent("files", isDirectory: true)
        let file = components.reduce(filesRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
        let standardizedRoot = filesRoot.standardizedFileURL.resolvingSymlinksInPath()
        let standardizedFile = file.standardizedFileURL.resolvingSymlinksInPath()
        guard standardizedFile.path.hasPrefix(standardizedRoot.path + "/") else {
            return nil
        }
        return standardizedFile
    }

    private func gitUntrackedPathHash(_ path: String, in repoRoot: String) throws -> String {
        try gitSingleLine(["hash-object", "--no-filters", "--", path], in: repoRoot)
    }

    private func gitUntrackedSnapshotFileHash(_ url: URL, in repoRoot: String) throws -> String {
        try gitSingleLine(["hash-object", "--no-filters", "--", url.path], in: repoRoot)
    }

    private func posixError(_ errnoValue: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errnoValue) ?? .EIO)
    }

    private func setPrivateDirectoryPermissions(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try setPrivateDirectoryPermissions(at: url)
    }

    private func copyPrivateFile(from sourceURL: URL, to destinationURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        let fd = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard fd >= 0 else {
            throw posixError(errno)
        }
        var shouldClose = true
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return
                }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                    if written < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw posixError(errno)
                    }
                    if written == 0 {
                        throw POSIXError(.EIO)
                    }
                    offset += written
                }
            }
            if Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) != 0 {
                throw posixError(errno)
            }
            if Darwin.close(fd) != 0 {
                shouldClose = false
                throw posixError(errno)
            }
            shouldClose = false
        } catch {
            if shouldClose {
                Darwin.close(fd)
            }
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func gitUntrackedPathHashes(
        paths: [String],
        in repoRoot: String,
        storePath: String
    ) throws -> (snapshotId: String?, hashes: [String: String]) {
        guard !paths.isEmpty else {
            return (nil, [:])
        }
        let snapshotId = UUID().uuidString
        guard let snapshotDirectory = agentTurnDiffBaselineStagedSnapshotDirectoryURL(
            snapshotId: snapshotId,
            storePath: storePath
        ) else {
            return (nil, [:])
        }
        try createPrivateDirectory(at: agentTurnDiffBaselineSnapshotStagingRootURL(storePath: storePath))
        try createPrivateDirectory(at: snapshotDirectory)
        let filesRoot = snapshotDirectory.appendingPathComponent("files", isDirectory: true)
        try createPrivateDirectory(at: filesRoot)
        var hashes: [String: String] = [:]
        var capturedBytes: UInt64 = 0
        for path in paths {
            guard hashes.count < CMUXAgentTurnUntrackedSnapshotLimits.maxFiles,
                  let sourceURL = safeRepoPathURL(relativePath: path, repoRoot: repoRoot),
                  let components = safeRelativePathComponents(path) else {
                continue
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                continue
            }
            let fileSize = UInt64((attributes[.size] as? NSNumber)?.int64Value ?? 0)
            guard fileSize <= CMUXAgentTurnUntrackedSnapshotLimits.maxFileBytes,
                  capturedBytes + fileSize <= CMUXAgentTurnUntrackedSnapshotLimits.maxTotalBytes else {
                continue
            }
            do {
                let destinationURL = components.reduce(filesRoot) { partial, component in
                    partial.appendingPathComponent(component, isDirectory: false)
                }
                try createPrivateDirectory(at: destinationURL.deletingLastPathComponent())
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try copyPrivateFile(from: sourceURL, to: destinationURL)
                let hash = try gitUntrackedSnapshotFileHash(destinationURL, in: repoRoot)
                hashes[path] = hash
                capturedBytes += fileSize
            } catch {
                continue
            }
        }
        if hashes.isEmpty {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            return (nil, [:])
        }
        return (snapshotId, hashes)
    }

    private func publishAgentTurnDiffBaselineSnapshot(snapshotId: String, storePath: String) throws {
        guard let stagedDirectory = agentTurnDiffBaselineStagedSnapshotDirectoryURL(
            snapshotId: snapshotId,
            storePath: storePath
        ), let snapshotDirectory = agentTurnDiffBaselineSnapshotDirectoryURL(
            snapshotId: snapshotId,
            storePath: storePath
        ) else {
            return
        }
        guard FileManager.default.fileExists(atPath: stagedDirectory.path) else {
            return
        }
        try createPrivateDirectory(at: snapshotDirectory.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: snapshotDirectory.path) {
            try FileManager.default.removeItem(at: snapshotDirectory)
        }
        try FileManager.default.moveItem(at: stagedDirectory, to: snapshotDirectory)
        try setPrivateDirectoryPermissions(at: snapshotDirectory)
    }

    private func removeAgentTurnDiffBaselineSnapshot(snapshotId: String, storePath: String) {
        if let snapshotDirectory = agentTurnDiffBaselineSnapshotDirectoryURL(
            snapshotId: snapshotId,
            storePath: storePath
        ) {
            try? FileManager.default.removeItem(at: snapshotDirectory)
        }
        if let stagedDirectory = agentTurnDiffBaselineStagedSnapshotDirectoryURL(
            snapshotId: snapshotId,
            storePath: storePath
        ) {
            try? FileManager.default.removeItem(at: stagedDirectory)
        }
    }

    private func joinedGitDiffPatches(_ patches: [String]) -> String {
        let trimmed = patches.map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return "" }
        return trimmed.joined(separator: "\n") + "\n"
    }

    func recordAgentTurnDiffBaseline(
        agent: String,
        sessionId: String,
        turnId: String?,
        cwd: String?,
        workspaceId: String,
        surfaceId: String,
        env: [String: String] = ProcessInfo.processInfo.environment,
        preserveExistingTurnBaseline: Bool = false
    ) throws {
        guard let cwd = normalizedDiffSourceValue(cwd),
              let workspaceId = normalizedDiffSourceValue(workspaceId),
              let surfaceId = normalizedDiffSourceValue(surfaceId) else {
            return
        }
        let repoRoot = try gitRepoRoot(startingAt: cwd)
        let baseCommit = try agentTurnDiffBaselineCommit(in: repoRoot)
        let untrackedPaths = try gitUntrackedPaths(in: repoRoot)
        let storePath = CMUXAgentTurnDiffBaselineFile.path(env: env)
        let untrackedSnapshot = try gitUntrackedPathHashes(
            paths: untrackedPaths,
            in: repoRoot,
            storePath: storePath
        )
        let record = CMUXAgentTurnDiffBaselineRecord(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            sessionId: normalizedDiffSourceValue(sessionId) ?? "",
            turnId: normalizedDiffSourceValue(turnId),
            agent: normalizedDiffSourceValue(agent) ?? "agent",
            repoRoot: repoRoot,
            baseCommit: baseCommit,
            untrackedPaths: untrackedPaths.isEmpty ? nil : untrackedPaths,
            untrackedPathHashes: untrackedSnapshot.hashes.isEmpty ? nil : untrackedSnapshot.hashes,
            untrackedSnapshotId: untrackedSnapshot.snapshotId,
            capturedAt: Date().timeIntervalSince1970
        )
        do {
            var removedRecords: [CMUXAgentTurnDiffBaselineRecord] = []
            var shouldRemoveNewSnapshot = untrackedSnapshot.snapshotId != nil
            try updateAgentTurnDiffBaselineStore(path: storePath, update: { store in
                func matchesCurrentScope(_ existing: CMUXAgentTurnDiffBaselineRecord) -> Bool {
                    standardizedDiffSourcePath(existing.repoRoot) == repoRoot &&
                        diffScopeIdentifierEquals(existing.workspaceId, workspaceId) &&
                        diffScopeIdentifierEquals(existing.surfaceId, surfaceId) &&
                        existing.sessionId == record.sessionId
                }

                let previousRecords = store.records
                if preserveExistingTurnBaseline,
                   let turnId = record.turnId,
                   store.records.contains(where: { matchesCurrentScope($0) && $0.turnId == turnId }) {
                    pruneAgentTurnDiffBaselineStore(&store)
                    removedRecords = previousRecords.filter { previous in
                        !store.records.contains { agentTurnDiffBaselineRecordEquals($0, previous) }
                    }
                    removedRecords.append(record)
                    return
                }

                if let snapshotId = untrackedSnapshot.snapshotId {
                    try publishAgentTurnDiffBaselineSnapshot(snapshotId: snapshotId, storePath: storePath)
                    shouldRemoveNewSnapshot = false
                }
                store.records.removeAll { existing in
                    guard matchesCurrentScope(existing) else {
                        return false
                    }
                    if let turnId = record.turnId {
                        return existing.turnId == turnId
                    }
                    return existing.turnId == nil
                }
                store.records.append(record)
                pruneAgentTurnDiffBaselineStore(&store)
                removedRecords = previousRecords.filter { previous in
                    !store.records.contains { agentTurnDiffBaselineRecordEquals($0, previous) }
                }
            }, afterWrite: { store in
                pruneAgentTurnDiffBaselineArtifacts(
                    storePath: storePath,
                    removedRecords: removedRecords,
                    retainedRecords: store.records
                )
            })
            if shouldRemoveNewSnapshot, let snapshotId = untrackedSnapshot.snapshotId {
                removeAgentTurnDiffBaselineSnapshot(snapshotId: snapshotId, storePath: storePath)
            }
        } catch {
            if let snapshotId = untrackedSnapshot.snapshotId {
                removeAgentTurnDiffBaselineSnapshot(snapshotId: snapshotId, storePath: storePath)
            }
            throw error
        }
    }

    private func agentTurnDiffBaselineCommit(in repoRoot: String) throws -> String {
        let stashResult = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", repoRoot, "stash", "create", "cmux last turn baseline"],
            timeout: 60
        )
        if stashResult.timedOut {
            throw CLIError(message: "git stash create timed out")
        }
        if stashResult.status == 0,
           let stashCommit = normalizedDiffSourceValue(stashResult.stdout) {
            _ = try gitStdout(["update-ref", agentTurnDiffBaselineRefName(for: stashCommit), stashCommit], in: repoRoot)
            return stashCommit
        }
        if let headCommit = try? gitSingleLine(["rev-parse", "HEAD"], in: repoRoot) {
            return headCommit
        }
        return try gitSingleLine(["hash-object", "-t", "tree", "/dev/null"], in: repoRoot)
    }

    private func agentTurnDiffBaselineRefName(for commit: String) -> String {
        "refs/cmux/last-turn/\(commit)"
    }

    private func agentTurnDiffBaselineUntrackedRefName(for blob: String) -> String {
        "refs/cmux/last-turn/untracked/\(blob)"
    }

    private func latestAgentTurnDiffBaseline(
        repoRoot: String,
        workspaceId: String,
        surfaceId: String,
        env: [String: String]
    ) throws -> CMUXAgentTurnDiffBaselineRecord {
        let store = try readAgentTurnDiffBaselineStore(path: CMUXAgentTurnDiffBaselineFile.path(env: env))
        let repoRoot = standardizedDiffSourcePath(repoRoot)
        let candidates = store.records.filter { record in
            standardizedDiffSourcePath(record.repoRoot) == repoRoot
                && diffScopeIdentifierEquals(record.workspaceId, workspaceId)
                && diffScopeIdentifierEquals(record.surfaceId, surfaceId)
        }
        guard let record = candidates.max(by: { $0.capturedAt < $1.capturedAt }) else {
            throw CLIError(message: "No last-turn diff baseline recorded for this workspace and surface yet. Run another agent turn with cmux hooks active, or use --unstaged, --staged, or --branch.")
        }
        return record
    }

    private func readAgentTurnDiffBaselineStore(path: String) throws -> CMUXAgentTurnDiffBaselineStore {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CMUXAgentTurnDiffBaselineStore()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CMUXAgentTurnDiffBaselineStore.self, from: data)
    }

    private func updateAgentTurnDiffBaselineStore(
        path: String,
        update: (inout CMUXAgentTurnDiffBaselineStore) throws -> Void,
        afterWrite: ((CMUXAgentTurnDiffBaselineStore) -> Void)? = nil
    ) throws {
        let url = URL(fileURLWithPath: path)
        try createPrivateDirectory(at: url.deletingLastPathComponent())
        let lockPath = path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open diff baseline lock: \(lockPath)")
        }
        defer { Darwin.close(fd) }

        if flock(fd, LOCK_EX) != 0 {
            throw CLIError(message: "Failed to lock diff baseline store: \(path)")
        }
        defer { _ = flock(fd, LOCK_UN) }
        if Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) != 0 {
            throw posixError(errno)
        }

        var store = (try? readAgentTurnDiffBaselineStore(path: path)) ?? CMUXAgentTurnDiffBaselineStore()
        try update(&store)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        afterWrite?(store)
    }

    private func pruneAgentTurnDiffBaselineStore(_ store: inout CMUXAgentTurnDiffBaselineStore) {
        let cutoff = Date().timeIntervalSince1970 - 60 * 60 * 24 * 7
        store.records = store.records
            .filter { $0.capturedAt >= cutoff }
            .sorted { $0.capturedAt > $1.capturedAt }
        if store.records.count > 200 {
            store.records.removeSubrange(200..<store.records.count)
        }
    }

    private func pruneAgentTurnDiffBaselineArtifacts(
        storePath: String,
        removedRecords: [CMUXAgentTurnDiffBaselineRecord],
        retainedRecords: [CMUXAgentTurnDiffBaselineRecord]
    ) {
        pruneAgentTurnDiffBaselineRefs(
            removedRecords: removedRecords,
            retainedRecords: retainedRecords
        )
        pruneAgentTurnDiffBaselineSnapshots(storePath: storePath, retainedRecords: retainedRecords)
    }

    private func pruneAgentTurnDiffBaselineRefs(
        removedRecords: [CMUXAgentTurnDiffBaselineRecord],
        retainedRecords: [CMUXAgentTurnDiffBaselineRecord]
    ) {
        var deletedKeys: Set<String> = []
        for record in removedRecords {
            let repoRoot = standardizedDiffSourcePath(record.repoRoot)
            let key = "\(repoRoot)\u{0}\(record.baseCommit)"
            guard deletedKeys.insert(key).inserted else { continue }
            let stillRetained = retainedRecords.contains { retained in
                standardizedDiffSourcePath(retained.repoRoot) == repoRoot
                    && retained.baseCommit == record.baseCommit
            }
            guard !stillRetained else { continue }
            _ = CLIProcessRunner.runProcess(
                executablePath: "/usr/bin/env",
                arguments: ["git", "-C", repoRoot, "update-ref", "-d", agentTurnDiffBaselineRefName(for: record.baseCommit)],
                timeout: 30
            )
        }
        var deletedBlobKeys: Set<String> = []
        for record in removedRecords {
            let repoRoot = standardizedDiffSourcePath(record.repoRoot)
            let blobs = Set(record.untrackedPathHashes.map { Array($0.values) } ?? [])
            for blob in blobs {
                let key = "\(repoRoot)\u{0}\(blob)"
                guard deletedBlobKeys.insert(key).inserted else { continue }
                let stillRetained = retainedRecords.contains { retained in
                    standardizedDiffSourcePath(retained.repoRoot) == repoRoot
                        && (retained.untrackedPathHashes?.values.contains(blob) ?? false)
                }
                guard !stillRetained else { continue }
                _ = CLIProcessRunner.runProcess(
                    executablePath: "/usr/bin/env",
                    arguments: ["git", "-C", repoRoot, "update-ref", "-d", agentTurnDiffBaselineUntrackedRefName(for: blob)],
                    timeout: 30
                )
            }
        }
    }

    private func pruneAgentTurnDiffBaselineSnapshots(
        storePath: String,
        retainedRecords: [CMUXAgentTurnDiffBaselineRecord]
    ) {
        let rootURL = agentTurnDiffBaselineSnapshotRootURL(storePath: storePath)
        let retainedSnapshotIds = Set(retainedRecords.compactMap(\.untrackedSnapshotId))
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries {
            guard !retainedSnapshotIds.contains(entry.lastPathComponent) else {
                continue
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func agentTurnDiffBaselineRecordEquals(
        _ lhs: CMUXAgentTurnDiffBaselineRecord,
        _ rhs: CMUXAgentTurnDiffBaselineRecord
    ) -> Bool {
        standardizedDiffSourcePath(lhs.repoRoot) == standardizedDiffSourcePath(rhs.repoRoot)
            && diffScopeIdentifierEquals(lhs.workspaceId, rhs.workspaceId)
            && diffScopeIdentifierEquals(lhs.surfaceId, rhs.surfaceId)
            && lhs.sessionId == rhs.sessionId
            && lhs.turnId == rhs.turnId
            && lhs.agent == rhs.agent
            && lhs.baseCommit == rhs.baseCommit
            && lhs.untrackedPaths == rhs.untrackedPaths
            && lhs.untrackedPathHashes == rhs.untrackedPathHashes
            && lhs.untrackedSnapshotId == rhs.untrackedSnapshotId
            && lhs.capturedAt == rhs.capturedAt
    }

    private func diffScopeIdentifierEquals(_ lhs: String, _ rhs: String) -> Bool {
        if let lhsUUID = UUID(uuidString: lhs),
           let rhsUUID = UUID(uuidString: rhs) {
            return lhsUUID == rhsUUID
        }
        return lhs == rhs
    }

    private func normalizedDiffSourceValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func standardizedDiffSourcePath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    private func diffViewerAppearance(socketPath: String, fontSizeOverride: Double?) -> DiffViewerAppearance {
        var appearance = defaultDiffViewerAppearance()
        let targetBundleIdentifier = themeTargetBundleIdentifier(socketPath: socketPath)
        for url in themeConfigSearchURLs(targetBundleIdentifier: targetBundleIdentifier) {
            guard let contents = readOptionalDiffViewerConfig(at: url) else { continue }
            applyDiffViewerGhosttyConfig(contents, to: &appearance)
        }
        if let fontSizeOverride {
            appearance.fontSize = fontSizeOverride
        }
        let themeSuffix = UUID().uuidString.prefix(8)
        appearance.lightTheme.generatedName = "cmux-ghostty-light-\(themeSuffix)"
        appearance.darkTheme.generatedName = "cmux-ghostty-dark-\(themeSuffix)"
        appearance.lightTheme.type = diffViewerThemeType(forBackground: appearance.lightTheme.background, fallback: "light")
        appearance.darkTheme.type = diffViewerThemeType(forBackground: appearance.darkTheme.background, fallback: "dark")
        return appearance
    }

    private func defaultDiffViewerAppearance() -> DiffViewerAppearance {
        var lightTheme = DiffViewerTheme(
            generatedName: "cmux-ghostty-light",
            ghosttyName: "Apple System Colors Light",
            type: "light",
            background: "#feffff",
            foreground: "#000000",
            selectionBackground: "#abd8ff",
            selectionForeground: "#000000",
            palette: [:]
        )
        applyDiffViewerThemeContents(diffViewerDefaultThemeConfigContents(preferredColorScheme: .light), to: &lightTheme)

        var darkTheme = DiffViewerTheme(
            generatedName: "cmux-ghostty-dark",
            ghosttyName: "Apple System Colors",
            type: "dark",
            background: "#1e1e1e",
            foreground: "#ffffff",
            selectionBackground: "#3f638b",
            selectionForeground: "#ffffff",
            palette: [:]
        )
        applyDiffViewerThemeContents(diffViewerDefaultThemeConfigContents(preferredColorScheme: .dark), to: &darkTheme)

        return DiffViewerAppearance(
            fontFamily: "Menlo",
            fontSize: 10,
            lightTheme: lightTheme,
            darkTheme: darkTheme
        )
    }

    private func applyDiffViewerGhosttyConfig(_ contents: String, to appearance: inout DiffViewerAppearance) {
        for line in contents.components(separatedBy: .newlines) {
            guard let (key, value) = diffViewerGhosttyAssignment(from: line) else { continue }

            switch key {
            case "font-family":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    appearance.fontFamily = trimmed
                }
            case "font-size":
                if let fontSize = diffViewerConfigFontSize(value) {
                    appearance.fontSize = fontSize
                }
            case "theme":
                applyDiffViewerThemeDirective(value, to: &appearance)
            default:
                applyDiffViewerThemeAssignment(key: key, value: value, to: &appearance.lightTheme)
                applyDiffViewerThemeAssignment(key: key, value: value, to: &appearance.darkTheme)
            }
        }
    }

    private func applyDiffViewerThemeDirective(_ rawValue: String, to appearance: inout DiffViewerAppearance) {
        let lightThemeName = resolveDiffViewerThemeName(from: rawValue, preferredColorScheme: .light)
        if let theme = loadDiffViewerGhosttyTheme(
            named: lightThemeName,
            generatedName: "cmux-ghostty-light",
            fallbackType: "light",
            baseTheme: appearance.lightTheme
        ) {
            appearance.lightTheme = theme
        } else if !lightThemeName.isEmpty {
            appearance.lightTheme.ghosttyName = lightThemeName
        }

        let darkThemeName = resolveDiffViewerThemeName(from: rawValue, preferredColorScheme: .dark)
        if let theme = loadDiffViewerGhosttyTheme(
            named: darkThemeName,
            generatedName: "cmux-ghostty-dark",
            fallbackType: "dark",
            baseTheme: appearance.darkTheme
        ) {
            appearance.darkTheme = theme
        } else if !darkThemeName.isEmpty {
            appearance.darkTheme.ghosttyName = darkThemeName
        }
    }

    private func loadDiffViewerGhosttyTheme(
        named rawThemeName: String,
        generatedName: String,
        fallbackType: String,
        baseTheme: DiffViewerTheme
    ) -> DiffViewerTheme? {
        let themeName = rawThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !themeName.isEmpty else { return nil }

        for candidateName in diffViewerThemeNameCandidates(from: themeName) {
            for directoryURL in themeDirectoryURLs() {
                let themeURL = directoryURL.appendingPathComponent(candidateName, isDirectory: false)
                guard let contents = try? String(contentsOf: themeURL, encoding: .utf8) else {
                    continue
                }

                var theme = baseTheme
                theme.generatedName = generatedName
                theme.ghosttyName = candidateName
                applyDiffViewerThemeContents(contents, to: &theme)
                theme.type = diffViewerThemeType(forBackground: theme.background, fallback: fallbackType)
                return theme
            }
        }

        return nil
    }

    private func applyDiffViewerThemeContents(_ contents: String, to theme: inout DiffViewerTheme) {
        for line in contents.components(separatedBy: .newlines) {
            guard let (key, value) = diffViewerGhosttyAssignment(from: line) else { continue }
            applyDiffViewerThemeAssignment(key: key, value: value, to: &theme)
        }
    }

    private func applyDiffViewerThemeAssignment(key: String, value: String, to theme: inout DiffViewerTheme) {
        switch key {
        case "background":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.background = color
            }
        case "foreground":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.foreground = color
            }
        case "selection-background":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.selectionBackground = color
            }
        case "selection-foreground":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.selectionForeground = color
            }
        case "palette":
            let paletteParts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard paletteParts.count == 2,
                  let index = Int(paletteParts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  (0...15).contains(index),
                  let color = normalizedDiffViewerHexColor(paletteParts[1]) else {
                return
            }
            theme.palette[index] = color
        default:
            break
        }
    }

    private func readOptionalDiffViewerConfig(at url: URL) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
            if let type = attributes[.type] as? FileAttributeType,
               type != .typeRegular && type != .typeSymbolicLink {
                return nil
            }
            if let size = attributes[.size] as? NSNumber, size.intValue == 0 {
                return nil
            }
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func diffViewerGhosttyAssignment(from line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2 else { return nil }

        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private func resolveDiffViewerThemeName(
        from rawThemeValue: String,
        preferredColorScheme: DiffViewerColorScheme
    ) -> String {
        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawThemeValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil {
                    fallbackTheme = entry
                }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil {
                    lightTheme = value
                }
            case "dark":
                if darkTheme == nil {
                    darkTheme = value
                }
            default:
                if fallbackTheme == nil {
                    fallbackTheme = value
                }
            }
        }

        switch preferredColorScheme {
        case .light:
            if let lightTheme {
                return lightTheme
            }
        case .dark:
            if let darkTheme {
                return darkTheme
            }
        }

        if let fallbackTheme {
            return fallbackTheme
        }
        return ""
    }

    private func diffViewerThemeNameCandidates(from rawName: String) -> [String] {
        var candidates: [String] = []
        let compatibilityAliasGroups = [
            ["Solarized Light", "iTerm2 Solarized Light"],
            ["Solarized Dark", "iTerm2 Solarized Dark"]
        ]

        func appendCandidate(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !candidates.contains(trimmed) {
                candidates.append(trimmed)
            }

            for group in compatibilityAliasGroups {
                if group.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    for alias in group where alias.caseInsensitiveCompare(trimmed) != .orderedSame {
                        if !candidates.contains(alias) {
                            candidates.append(alias)
                        }
                    }
                }
            }
        }

        var queue: [String] = [rawName]
        while let current = queue.popLast() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            appendCandidate(trimmed)

            let lower = trimmed.lowercased()
            if lower.hasPrefix("builtin ") {
                let stripped = String(trimmed.dropFirst("builtin ".count))
                appendCandidate(stripped)
                queue.append(stripped)
            }

            if let range = trimmed.range(
                of: #"\s*\(builtin\)\s*$"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                let stripped = String(trimmed[..<range.lowerBound])
                appendCandidate(stripped)
                queue.append(stripped)
            }
        }

        return candidates
    }

    private func normalizedDiffViewerHexColor(_ rawValue: String) -> String? {
        var hex = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else { return nil }

        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 else { return nil }
        return "#\(hex.lowercased())"
    }

    private func diffViewerThemeType(forBackground background: String, fallback: String) -> String {
        guard let rgb = diffViewerRGBColor(background) else {
            return fallback
        }
        let luminance = (0.2126 * rgb.red) + (0.7152 * rgb.green) + (0.0722 * rgb.blue)
        return luminance > 0.55 ? "light" : "dark"
    }

    private func diffViewerRGBColor(_ rawValue: String) -> (red: Double, green: Double, blue: Double)? {
        guard let color = normalizedDiffViewerHexColor(rawValue) else { return nil }
        let hex = String(color.dropFirst())
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return (
            red: Double((value & 0xFF0000) >> 16) / 255.0,
            green: Double((value & 0x00FF00) >> 8) / 255.0,
            blue: Double(value & 0x0000FF) / 255.0
        )
    }

    private func isUsableDiffViewerFontSize(_ size: Double) -> Bool {
        size.isFinite && size > 0 && size <= 96
    }

    private func diffViewerConfigFontSize(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(trimmed),
              isUsableDiffViewerFontSize(size) else {
            return nil
        }
        return roundedDiffViewerMetric(size)
    }

    private func roundedDiffViewerMetric(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func diffViewerDefaultThemeConfigContents(preferredColorScheme: DiffViewerColorScheme) -> String {
        switch preferredColorScheme {
        case .light:
            return """
            palette = 0=#1a1a1a
            palette = 1=#cc372e
            palette = 2=#26a439
            palette = 3=#cdac08
            palette = 4=#0869cb
            palette = 5=#9647bf
            palette = 6=#479ec2
            palette = 7=#98989d
            palette = 8=#464646
            palette = 9=#ff453a
            palette = 10=#32d74b
            palette = 11=#e5bc00
            palette = 12=#0a84ff
            palette = 13=#bf5af2
            palette = 14=#69c9f2
            palette = 15=#ffffff
            background = #feffff
            foreground = #000000
            selection-background = #abd8ff
            selection-foreground = #000000
            """
        case .dark:
            return """
            palette = 0=#1a1a1a
            palette = 1=#cc372e
            palette = 2=#26a439
            palette = 3=#cdac08
            palette = 4=#0869cb
            palette = 5=#9647bf
            palette = 6=#479ec2
            palette = 7=#98989d
            palette = 8=#464646
            palette = 9=#ff453a
            palette = 10=#32d74b
            palette = 11=#ffd60a
            palette = 12=#0a84ff
            palette = 13=#bf5af2
            palette = 14=#76d6ff
            palette = 15=#ffffff
            background = #1e1e1e
            foreground = #ffffff
            selection-background = #3f638b
            selection-foreground = #ffffff
            """
        }
    }

    private func writeDiffViewer(
        rawInput: String?,
        source: DiffSource?,
        titleOverride: String?,
        layout: String,
        appearance: DiffViewerAppearance,
        context: DiffSourceContext
    ) throws -> DiffViewerWriteResult {
        if let source {
            return try writeGitDiffViewerHTMLSet(
                selectedSource: source,
                titleOverride: titleOverride,
                layout: layout,
                appearance: appearance,
                context: context
            )
        }

        let input = try readDiffInput(rawInput, source: nil, context: context)
        if input.remotePatchURL == nil {
            let trimmedPatch = input.patch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPatch.isEmpty else {
                throw CLIError(message: input.emptyMessage ?? "diff input is empty")
            }
        }

        let title = titleOverride ?? input.defaultTitle
        let directory = try diffViewerDirectory()
        let origin = try diffViewerHTTPServerOrigin(rootDirectory: directory)
        let mapper = DiffViewerURLMapper(
            token: UUID().uuidString.lowercased(),
            rootDirectory: directory,
            origin: origin
        )
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "diff-\(timestamp)-\(UUID().uuidString.prefix(8)).html"
        let viewerFileURL = directory.appendingPathComponent(filename, isDirectory: false)
        try writeDiffViewerHTML(
            to: viewerFileURL,
            patch: input.patch,
            title: title,
            sourceLabel: input.sourceLabel,
            externalURL: input.externalURL,
            remotePatchURL: input.remotePatchURL,
            layout: layout,
            appearance: appearance,
            sourceOptions: []
        )
        let assets = try ensureDiffViewerAssets(nextTo: viewerFileURL)
        let allowedFiles = try diffViewerAllowedFiles(
            pageURLs: [viewerFileURL],
            assets: assets,
            mapper: mapper,
            remotePatchURLsByPagePath: remotePatchURLMap(pageURL: viewerFileURL, remoteURL: input.remotePatchURL)
        )
        try writeDiffViewerHTTPManifest(
            token: mapper.token,
            files: allowedFiles,
            rootDirectory: directory
        )
        return DiffViewerWriteResult(
            fileURL: viewerFileURL,
            url: try mapper.viewerURL(for: viewerFileURL),
            title: title,
            input: input,
            allowedFiles: allowedFiles
        )
    }

    private func writeGitDiffViewerHTMLSet(
        selectedSource: DiffSource,
        titleOverride: String?,
        layout: String,
        appearance: DiffViewerAppearance,
        context: DiffSourceContext
    ) throws -> DiffViewerWriteResult {
        let directory = try diffViewerDirectory()
        let origin = try diffViewerHTTPServerOrigin(rootDirectory: directory)
        let mapper = DiffViewerURLMapper(
            token: UUID().uuidString.lowercased(),
            rootDirectory: directory,
            origin: origin
        )
        let timestamp = Int(Date().timeIntervalSince1970)
        let groupID = "\(timestamp)-\(UUID().uuidString.prefix(8))"
        let requestedSource = selectedSource
        let repoRoot = try gitRepoRootForDiff(context)
        let explicitBranchBaseRef = normalizedDiffSourceValue(context.branchBaseRef)
        var selectedSource = requestedSource
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
        let selectedInput: DiffInput
        do {
            selectedInput = try nonEmptyGitDiffInput(source: selectedSource, context: selectedContext)
        } catch let error as EmptyDiffSourceError {
            guard selectedSource != .lastTurn else {
                throw CLIError(message: error.message)
            }
            var fallback: (source: DiffSource, context: DiffSourceContext, input: DiffInput)?
            for candidate in DiffSource.allCases where candidate != selectedSource {
                guard let candidateContext = try? sourceContext(for: candidate, repoRoot: repoRoot),
                      let candidateInput = try? nonEmptyGitDiffInput(source: candidate, context: candidateContext) else {
                    continue
                }
                fallback = (candidate, candidateContext, candidateInput)
                break
            }
            guard let fallback else { throw CLIError(message: error.message) }
            selectedSource = fallback.source
            selectedContext = fallback.context
            selectedInput = fallback.input
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
        for source in DiffSource.allCases where source != selectedSource {
            if let url = fileURLs[source] {
                try writePendingDiffViewerHTML(
                    to: url,
                    title: source.title,
                    message: "\(CMUXDiffViewerLocalization.string("diffViewer.loadingDiff", defaultValue: "Loading diff...")) \(source.menuLabel)",
                    pollForReplacement: true
                )
                var pageContext = selectedContext
                if source == .branch {
                    pageContext.branchBaseRef = branchBaseForOptions
                } else {
                    pageContext.branchBaseRef = nil
                }
                deferredPages.append(
                    DiffViewerDeferredSourcePage(
                        source: source,
                        url: url,
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
                try writePendingDiffViewerHTML(
                    to: url,
                    title: option.label,
                    message: "\(CMUXDiffViewerLocalization.string("diffViewer.loadingDiff", defaultValue: "Loading diff...")) \(option.label)",
                    pollForReplacement: true
                )
                deferredPages.append(
                    DiffViewerDeferredSourcePage(
                        source: source,
                        url: url,
                        titleOverride: source == selectedSource ? titleOverride : nil,
                        context: DiffSourceContext(
                            workspaceId: selectedContext.workspaceId,
                            surfaceId: selectedContext.surfaceId,
                            repoRoot: option.repoRoot,
                            branchBaseRef: source == .branch ? explicitBranchBaseRef : selectedContext.branchBaseRef
                        ),
                        sourceOptions: sourceOptionsForRepo(selected: source, selectedRepoRoot: option.repoRoot),
                        repoOptions: repoOptionsForSource(source, selectedRepoRoot: option.repoRoot),
                        baseOptions: []
                    )
                )
            }
        }

        for option in baseCandidates where !(branchBaseForOptions.map { $0 == option.ref } ?? false) {
            guard let url = baseFileURLs[option.ref] else { continue }
            try writePendingDiffViewerHTML(
                to: url,
                title: option.label,
                message: "\(CMUXDiffViewerLocalization.string("diffViewer.loadingDiff", defaultValue: "Loading diff...")) \(option.label)",
                pollForReplacement: true
            )
            var pageContext = selectedContext
            pageContext.branchBaseRef = option.ref
            deferredPages.append(
                DiffViewerDeferredSourcePage(
                    source: .branch,
                    url: url,
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

        try writeDiffViewerHTML(
            to: selectedFileURL,
            patch: selectedInput.patch,
            title: titleOverride ?? selectedInput.defaultTitle,
            sourceLabel: selectedInput.sourceLabel,
            externalURL: selectedInput.externalURL,
            remotePatchURL: selectedInput.remotePatchURL,
            layout: layout,
            appearance: appearance,
            sourceOptions: sourceOptions,
            repoOptions: selectedRepoOptions,
            baseOptions: selectedSource == .branch ? baseOptions : [],
            repoRoot: repoRoot,
            branchBaseRef: selectedSource == .branch ? selectedContext.branchBaseRef : nil
        )
        let assets = try ensureDiffViewerAssets(nextTo: selectedFileURL)
        let pageURLs = [selectedFileURL] + deferredPages.map(\.url)
        let allowedFiles = try diffViewerAllowedFiles(
            pageURLs: pageURLs,
            assets: assets,
            mapper: mapper
        )
        try writeDiffViewerHTTPManifest(
            token: mapper.token,
            files: allowedFiles,
            rootDirectory: directory
        )

        return DiffViewerWriteResult(
            fileURL: selectedFileURL,
            url: selectedURL,
            title: titleOverride ?? selectedInput.defaultTitle,
            input: selectedInput,
            allowedFiles: allowedFiles,
            deferredSourceSet: DiffViewerDeferredSourceSet(
                pages: deferredPages,
                layout: layout,
                appearance: appearance
            )
        )
    }

    private func completeDeferredDiffViewerSources(_ sourceSet: DiffViewerDeferredSourceSet?) {
        guard let sourceSet else { return }
        for page in sourceSet.pages {
            do {
                var pageContext = page.context
                if page.source == .branch {
                    let repoRoot = try gitRepoRootForDiff(pageContext)
                    pageContext.repoRoot = repoRoot
                    pageContext.branchBaseRef = try resolvedGitBranchDiffBaseRef(pageContext.branchBaseRef, in: repoRoot)
                }
                let input = try nonEmptyGitDiffInput(source: page.source, context: pageContext)
                try writeDiffViewerHTML(
                    to: page.url,
                    patch: input.patch,
                    title: page.titleOverride ?? input.defaultTitle,
                    sourceLabel: input.sourceLabel,
                    externalURL: input.externalURL,
                    remotePatchURL: input.remotePatchURL,
                    layout: sourceSet.layout,
                    appearance: sourceSet.appearance,
                    sourceOptions: page.sourceOptions,
                    repoOptions: page.repoOptions,
                    baseOptions: page.baseOptions,
                    repoRoot: pageContext.repoRoot,
                    branchBaseRef: page.source == .branch ? pageContext.branchBaseRef : nil
                )
            } catch {
                let message = diffViewerErrorMessage(error)
                try? writePendingDiffViewerHTML(to: page.url, title: page.source.title, message: message, pollForReplacement: false)
            }
        }
    }

    private func nonEmptyGitDiffInput(source: DiffSource, context: DiffSourceContext) throws -> DiffInput {
        let input = try readGitDiffInput(source: source, context: context)
        guard !input.patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmptyDiffSourceError(message: input.emptyMessage ?? "No changes to diff.")
        }
        return input
    }

    private func diffViewerErrorMessage(_ error: Error) -> String {
        if let error = error as? CLIError {
            return error.message
        }
        if let error = error as? EmptyDiffSourceError {
            return error.message
        }
        return error.localizedDescription
    }

    private func diffViewerSourceOptions(
        selected: DiffSource,
        urls: [DiffSource: URL]
    ) -> [DiffViewerSourceOption] {
        DiffSource.allCases.map { option in
            DiffViewerSourceOption(
                value: option.slug,
                label: option.menuLabel,
                selected: option == selected,
                url: urls[option]?.absoluteString,
                disabled: false,
                message: nil,
                sourceLabel: nil
            )
        }
    }

    private func diffViewerRepoOptions(
        selectedRepoRoot: String,
        candidates: [DiffViewerRepoOption],
        urls: [String: URL]
    ) -> [DiffViewerSourceOption] {
        guard candidates.count > 1 else { return [] }
        return candidates.map { option in
            DiffViewerSourceOption(
                value: option.repoRoot,
                label: option.label,
                selected: option.repoRoot == selectedRepoRoot,
                url: urls[option.repoRoot]?.absoluteString,
                disabled: false,
                message: option.repoRoot,
                sourceLabel: nil
            )
        }
    }

    private func diffViewerBranchBaseOptions(
        selectedBaseRef: String?,
        candidates: [DiffViewerBranchBaseOption],
        urls: [String: URL]
    ) -> [DiffViewerSourceOption] {
        guard candidates.count > 1 else { return [] }
        return candidates.map { option in
            DiffViewerSourceOption(
                value: option.ref,
                label: option.label,
                selected: selectedBaseRef.map { $0 == option.ref } ?? false,
                url: urls[option.ref]?.absoluteString,
                disabled: false,
                message: option.ref,
                sourceLabel: nil
            )
        }
    }

    private func gitDiffViewerRepoOptions(selectedRepoRoot: String) -> [DiffViewerRepoOption] {
        let selectedURL = URL(fileURLWithPath: selectedRepoRoot, isDirectory: true).standardizedFileURL
        var candidateURLs: [URL] = [selectedURL]
        let parentURL = selectedURL.deletingLastPathComponent()

        if parentURL.lastPathComponent == "worktrees" {
            let hqURL = parentURL.deletingLastPathComponent()
            let primaryRepoURL = hqURL.appendingPathComponent("repo", isDirectory: true)
            if diffViewerDirectoryContainsGitMetadata(primaryRepoURL) {
                candidateURLs.append(primaryRepoURL)
            }
        }

        candidateURLs.append(contentsOf: gitChildRepoURLs(in: parentURL))

        if selectedURL.lastPathComponent == "repo" {
            let worktreesURL = parentURL.appendingPathComponent("worktrees", isDirectory: true)
            candidateURLs.append(contentsOf: gitChildRepoURLs(in: worktreesURL))
        }

        var seen: Set<String> = []
        var roots: [String] = []
        for candidateURL in candidateURLs {
            guard roots.count < DiffViewerLimits.repoOptions,
                  let root = try? gitRepoRoot(startingAt: candidateURL.path),
                  !seen.contains(root) else {
                continue
            }
            seen.insert(root)
            roots.append(root)
        }

        if !seen.contains(selectedRepoRoot) {
            roots.insert(selectedRepoRoot, at: 0)
        }

        return roots.map { root in
            DiffViewerRepoOption(
                repoRoot: root,
                label: gitDiffViewerRepoLabel(root, selectedRepoRoot: selectedRepoRoot)
            )
        }
    }

    private func gitChildRepoURLs(in directoryURL: URL) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        return children
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
                    diffViewerDirectoryContainsGitMetadata(url)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func diffViewerDirectoryContainsGitMetadata(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git", isDirectory: false).path)
    }

    private func gitDiffViewerRepoLabel(_ repoRoot: String, selectedRepoRoot: String) -> String {
        let repoURL = URL(fileURLWithPath: repoRoot, isDirectory: true).standardizedFileURL
        let selectedURL = URL(fileURLWithPath: selectedRepoRoot, isDirectory: true).standardizedFileURL
        let selectedParent = selectedURL.deletingLastPathComponent()
        let selectedGrandparent = selectedParent.deletingLastPathComponent()
        if selectedParent.lastPathComponent == "worktrees",
           repoURL.deletingLastPathComponent() == selectedParent {
            return "worktrees/\(repoURL.lastPathComponent)"
        }
        if repoURL.deletingLastPathComponent() == selectedGrandparent,
           repoURL.lastPathComponent == "repo" {
            return "repo"
        }
        if repoURL.deletingLastPathComponent() == selectedParent {
            let name = repoURL.lastPathComponent
            return name.isEmpty ? repoRoot : name
        }
        return repoRoot
    }

    private func gitDiffViewerBranchBaseOptions(
        in repoRoot: String,
        selectedBaseRef: String?
    ) -> [DiffViewerBranchBaseOption] {
        var refs: [String] = []
        func appendRef(_ ref: String?) {
            guard let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ref.isEmpty,
                  !refs.contains(ref),
                  !ref.hasSuffix("/HEAD") else {
                return
            }
            refs.append(ref)
        }

        appendRef(selectedBaseRef)
        appendRef(try? gitBranchDiffBaseRef(in: repoRoot))
        if let listing = try? gitStdout(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes", "refs/heads"],
            in: repoRoot
        ) {
            for line in listing.split(whereSeparator: \.isNewline).map(String.init) where refs.count < DiffViewerLimits.branchBaseOptions {
                appendRef(line)
            }
        }

        return refs.map { ref in
            DiffViewerBranchBaseOption(ref: ref, label: ref)
        }
    }

    private func writePendingDiffViewerHTML(
        to url: URL,
        title: String,
        message: String,
        pollForReplacement: Bool
    ) throws {
        let escapedTitle = htmlEscaped(title)
        let escapedMessage = htmlEscaped(message)
        let pendingAttribute = pollForReplacement ? " data-cmux-diff-pending=\"true\"" : ""
        let pollScript = pollForReplacement ? """
          <script>
            function replaceDocumentWith(text) {
              document.open();
              document.write(text);
              document.close();
            }

            async function applyReplacementFrom(response) {
              const text = await response.text();
              if (!response.ok) {
                if (text.trim() !== "") {
                  replaceDocumentWith(text);
                }
                return false;
              }
              if (text.includes("data-cmux-diff-pending=\\"true\\"")) {
                return false;
              }
              replaceDocumentWith(text);
              return true;
            }

            async function waitForReplacement() {
              try {
                const response = await fetch("/__cmux_diff_viewer_wait" + location.pathname, { cache: "no-store" });
                await applyReplacementFrom(response);
              } catch (error) {
                document.documentElement.dataset.cmuxDiffWait = "failed";
                console.warn("cmux diff viewer deferred load failed", error);
              }
            }

            waitForReplacement();
          </script>
        """ : ""
        let html = """
        <!doctype html>
        <html\(pendingAttribute)>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedTitle)</title>
          <style>
            :root { color-scheme: light dark; }
            body {
              margin: 0;
              min-height: 100vh;
              display: grid;
              place-items: center;
              background: Canvas;
              color: CanvasText;
              font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
            }
            main {
              display: grid;
              gap: 10px;
              padding: 24px;
              max-width: 520px;
            }
            h1 {
              margin: 0;
              font-size: 14px;
              font-weight: 600;
            }
            p {
              margin: 0;
              opacity: 0.72;
              line-height: 1.45;
            }
          </style>
        </head>
        <body>
          <main>
            <h1>\(escapedTitle)</h1>
            <p>\(escapedMessage)</p>
          </main>
        \(pollScript)
        </body>
        </html>
        """
        try writeDiffViewerPatchSidecar("", for: url)
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    private func diffViewerDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(getuid())", isDirectory: true)
        try ensureSecureDiffViewerDirectory(directory)
        pruneDiffViewerFiles(in: directory)
        return directory
    }

    private func ensureSecureDiffViewerDirectory(_ directory: URL) throws {
        let path = directory.path
        if mkdir(path, mode_t(0o700)) != 0 {
            let mkdirErrno = errno
            guard mkdirErrno == EEXIST else {
                throw CLIError(message: "Failed to create diff viewer directory: \(posixErrorMessage(mkdirErrno))")
            }
        }

        try validateSecureDiffViewerDirectory(directory, repairPermissions: true)
    }

    private func validateSecureDiffViewerDirectory(_ directory: URL, repairPermissions: Bool) throws {
        let path = directory.path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw CLIError(message: "Failed to inspect diff viewer directory: \(posixErrorMessage(errno))")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw CLIError(message: "Unsafe diff viewer directory is not a directory: \(path)")
        }
        guard info.st_uid == getuid() else {
            throw CLIError(message: "Unsafe diff viewer directory is not owned by the current user: \(path)")
        }

        let permissionBits = info.st_mode & mode_t(0o777)
        guard permissionBits == mode_t(0o700) else {
            guard repairPermissions else {
                throw CLIError(message: "Unsafe diff viewer directory permissions: \(path)")
            }
            if chmod(path, mode_t(0o700)) != 0 {
                throw CLIError(message: "Failed to secure diff viewer directory: \(posixErrorMessage(errno))")
            }
            try validateSecureDiffViewerDirectory(directory, repairPermissions: false)
            return
        }
    }

    func runDiffViewerServerCommand(commandArgs: [String]) throws {
        var rootPath: String?
        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if arg == "--root" {
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "diff-viewer-server --root requires a path")
                }
                rootPath = commandArgs[index + 1]
                index += 2
                continue
            }
            throw CLIError(message: "Unexpected diff-viewer-server argument: \(arg)")
        }

        guard let rootPath else {
            throw CLIError(message: "diff-viewer-server requires --root")
        }

        let rootDirectory = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try validateSecureDiffViewerDirectory(rootDirectory, repairPermissions: false)
        try runDiffViewerHTTPServer(rootDirectory: rootDirectory)
    }

    private func diffViewerHTTPServerOrigin(rootDirectory: URL) throws -> URL {
        let rootDirectory = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        try validateSecureDiffViewerDirectory(rootDirectory, repairPermissions: false)

        if let state = try? readDiffViewerHTTPServerState(rootDirectory: rootDirectory),
           state.rootPath == rootDirectory.path,
           (1...65535).contains(state.port),
           diffViewerHTTPServerIsReachable(port: state.port) {
            guard let url = URL(string: "http://127.0.0.1:\(state.port)") else {
                throw CLIError(message: "Failed to build diff viewer server URL")
            }
            return url
        }

        return try startDiffViewerHTTPServer(rootDirectory: rootDirectory)
    }

    private func readDiffViewerHTTPServerState(rootDirectory: URL) throws -> DiffViewerHTTPServerState {
        let data = try Data(contentsOf: diffViewerHTTPServerStateURL(rootDirectory: rootDirectory))
        return try JSONDecoder().decode(DiffViewerHTTPServerState.self, from: data)
    }

    private func writeDiffViewerHTTPServerState(_ state: DiffViewerHTTPServerState, rootDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = diffViewerHTTPServerStateURL(rootDirectory: rootDirectory)
        try encoder.encode(state).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func startDiffViewerHTTPServer(rootDirectory: URL) throws -> URL {
        guard let executableURL = resolvedExecutableURL() else {
            throw CLIError(message: "Failed to resolve cmux executable for diff viewer server")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["diff-viewer-server", "--root", rootDirectory.path]
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        if let nullInput = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = nullInput
        }
        if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardError = nullOutput
        }

        do {
            try process.run()
        } catch {
            throw CLIError(message: "Failed to start diff viewer server: \(error.localizedDescription)")
        }

        let port = try readDiffViewerHTTPServerPort(from: stdoutPipe.fileHandleForReading, process: process)
        guard diffViewerHTTPServerIsReachable(port: port) else {
            process.terminate()
            throw CLIError(message: "Diff viewer server did not become reachable")
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw CLIError(message: "Failed to build diff viewer server URL")
        }
        return url
    }

    private func readDiffViewerHTTPServerPort(from handle: FileHandle, process: Process) throws -> Int {
        let finished = DispatchSemaphore(value: 0)
        var result: Result<Int, Error>?

        DispatchQueue.global(qos: .utility).async {
            var data = Data()
            while data.count < 64 {
                let byte = handle.readData(ofLength: 1)
                if byte.isEmpty {
                    break
                }
                if byte == Data([0x0a]) {
                    break
                }
                data.append(byte)
            }

            let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let port = Int(line), (1...65535).contains(port) {
                result = .success(port)
            } else {
                result = .failure(CLIError(message: "Diff viewer server returned an invalid port"))
            }
            finished.signal()
        }

        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            throw CLIError(message: "Timed out starting diff viewer server")
        }

        switch result {
        case .success(let port):
            return port
        case .failure(let error):
            process.terminate()
            throw error
        case .none:
            process.terminate()
            throw CLIError(message: "Failed to read diff viewer server port")
        }
    }

    private func diffViewerHTTPServerIsReachable(port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/__cmux_diff_viewer_healthz") else {
            return false
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let finished = DispatchSemaphore(value: 0)
        var reachable = false
        let task = session.dataTask(with: url) { data, response, _ in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            reachable = statusCode == 200 && data == Self.diffViewerHTTPServerHealthResponse
            finished.signal()
        }
        task.resume()
        if finished.wait(timeout: .now() + 1) == .timedOut {
            task.cancel()
            return false
        }
        return reachable
    }

    private func writeDiffViewerHTTPManifest(
        token: String,
        files: [DiffViewerAllowedFile],
        rootDirectory: URL
    ) throws {
        guard diffViewerHTTPIsValidToken(token) else {
            throw CLIError(message: "Invalid diff viewer token")
        }
        guard !files.isEmpty, files.count <= 4096 else {
            throw CLIError(message: "Invalid diff viewer allowlist size")
        }
        let manifest = DiffViewerHTTPManifest(token: token, files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = diffViewerHTTPManifestURL(token: token, rootDirectory: rootDirectory)
        try encoder.encode(manifest).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func runDiffViewerHTTPServer(rootDirectory: URL) throws -> Never {
        _ = signal(SIGPIPE, SIG_IGN)
        let serverFD = try bindDiffViewerHTTPServerSocket()
        let port = try diffViewerHTTPServerPort(fileDescriptor: serverFD)
        let manifestCache = DiffViewerHTTPManifestCache(owner: self, rootDirectory: rootDirectory)
        defer { close(serverFD) }

        try writeDiffViewerHTTPServerState(
            DiffViewerHTTPServerState(port: port, pid: getpid(), rootPath: rootDirectory.path),
            rootDirectory: rootDirectory
        )
        FileHandle.standardOutput.write(Data("\(port)\n".utf8))

        while true {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                throw CLIError(message: "Diff viewer server accept failed: \(posixErrorMessage(errno))")
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleDiffViewerHTTPConnection(
                    fileDescriptor: clientFD,
                    port: port,
                    manifestCache: manifestCache
                )
            }
        }
    }

    private final class DiffViewerHTTPManifestCache: @unchecked Sendable {
        private let owner: CMUXCLI
        private let rootDirectory: URL
        private let lock = NSLock()
        private var filesByToken: [String: [String: DiffViewerAllowedFile]] = [:]

        init(owner: CMUXCLI, rootDirectory: URL) {
            self.owner = owner
            self.rootDirectory = rootDirectory
        }

        func file(token: String, requestPath: String) throws -> DiffViewerAllowedFile? {
            lock.lock()
            if let files = filesByToken[token] {
                let file = files[requestPath]
                lock.unlock()
                return file
            }
            lock.unlock()

            let files = try owner.loadDiffViewerHTTPManifestFiles(token: token, rootDirectory: rootDirectory)

            lock.lock()
            filesByToken[token] = files
            let file = files[requestPath]
            lock.unlock()
            return file
        }
    }

    private func bindDiffViewerHTTPServerSocket() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError(message: "Failed to create diff viewer server socket: \(posixErrorMessage(errno))")
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let bindErrno = errno
            close(fd)
            throw CLIError(message: "Failed to bind diff viewer server socket: \(posixErrorMessage(bindErrno))")
        }

        guard listen(fd, SOMAXCONN) == 0 else {
            let listenErrno = errno
            close(fd)
            throw CLIError(message: "Failed to listen on diff viewer server socket: \(posixErrorMessage(listenErrno))")
        }

        return fd
    }

    private func diffViewerHTTPServerPort(fileDescriptor fd: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard result == 0 else {
            throw CLIError(message: "Failed to inspect diff viewer server socket: \(posixErrorMessage(errno))")
        }
        return Int(in_port_t(bigEndian: address.sin_port))
    }

    private func handleDiffViewerHTTPConnection(
        fileDescriptor fd: Int32,
        port: Int,
        manifestCache: DiffViewerHTTPManifestCache
    ) {
        defer { close(fd) }

        do {
            guard let request = try readDiffViewerHTTPRequest(fileDescriptor: fd) else {
                return
            }
            guard request.method == "GET" || request.method == "HEAD" else {
                try sendDiffViewerHTTPResponse(
                    fileDescriptor: fd,
                    status: 405,
                    reason: "Method Not Allowed",
                    headers: ["Allow": "GET, HEAD"],
                    body: Data("405 Method Not Allowed\n".utf8),
                    omitBody: request.method == "HEAD"
                )
                return
            }

            if request.path == "/__cmux_diff_viewer_healthz" {
                try sendDiffViewerHTTPResponse(
                    fileDescriptor: fd,
                    status: 200,
                    reason: "OK",
                    headers: ["Content-Type": "text/plain; charset=utf-8"],
                    body: Self.diffViewerHTTPServerHealthResponse,
                    omitBody: request.method == "HEAD"
                )
                return
            }

            if request.path.hasPrefix("/__cmux_diff_viewer_wait/") {
                try sendDiffViewerHTTPWaitForReplacement(
                    requestPath: request.path,
                    fileDescriptor: fd,
                    port: port,
                    manifestCache: manifestCache,
                    omitBody: request.method == "HEAD"
                )
                return
            }

            guard let file = try diffViewerHTTPAllowedFile(
                requestPath: request.path,
                manifestCache: manifestCache
            ) else {
                try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: request.method == "HEAD")
                return
            }

            try sendDiffViewerHTTPFile(
                file,
                fileDescriptor: fd,
                port: port,
                omitBody: request.method == "HEAD"
            )
        } catch {
            try? sendDiffViewerHTTPResponse(
                fileDescriptor: fd,
                status: 500,
                reason: "Internal Server Error",
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data("500 Internal Server Error\n".utf8),
                omitBody: false
            )
        }
    }

    private struct DiffViewerHTTPRequest {
        var method: String
        var path: String
    }

    private func readDiffViewerHTTPRequest(fileDescriptor fd: Int32) throws -> DiffViewerHTTPRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let headerEnd = Data("\r\n\r\n".utf8)

        while data.count < 16 * 1024 {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return recv(fd, baseAddress, rawBuffer.count, 0)
            }
            if count == 0 {
                return nil
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw CLIError(message: "Failed to read diff viewer request: \(posixErrorMessage(errno))")
            }
            buffer.withUnsafeBufferPointer { pointer in
                if let baseAddress = pointer.baseAddress {
                    data.append(baseAddress, count: count)
                }
            }
            if data.range(of: headerEnd) != nil {
                break
            }
        }

        guard let header = String(data: data, encoding: .utf8),
              let firstLine = header.components(separatedBy: "\r\n").first else {
            throw CLIError(message: "Invalid diff viewer request")
        }
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw CLIError(message: "Invalid diff viewer request")
        }

        let method = String(parts[0]).uppercased()
        var target = String(parts[1])
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            guard let components = URLComponents(string: target) else {
                throw CLIError(message: "Invalid diff viewer request target")
            }
            target = components.percentEncodedPath
        }
        if let queryIndex = target.firstIndex(of: "?") {
            target = String(target[..<queryIndex])
        }
        guard target.hasPrefix("/") else {
            throw CLIError(message: "Invalid diff viewer request path")
        }
        return DiffViewerHTTPRequest(method: method, path: target)
    }

    private func diffViewerHTTPAllowedFile(
        requestPath rawPath: String,
        manifestCache: DiffViewerHTTPManifestCache
    ) throws -> DiffViewerAllowedFile? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let withoutLeadingSlash = String(trimmed.dropFirst())
        guard let separator = withoutLeadingSlash.firstIndex(of: "/") else {
            return nil
        }

        let token = String(withoutLeadingSlash[..<separator])
        let requestPath = "/" + String(withoutLeadingSlash[withoutLeadingSlash.index(after: separator)...])
        guard diffViewerHTTPIsValidToken(token),
              diffViewerHTTPIsValidRequestPath(requestPath) else {
            return nil
        }
        return try manifestCache.file(token: token, requestPath: requestPath)
    }

    private func sendDiffViewerHTTPWaitForReplacement(
        requestPath rawPath: String,
        fileDescriptor fd: Int32,
        port: Int,
        manifestCache: DiffViewerHTTPManifestCache,
        omitBody: Bool
    ) throws {
        let prefix = "/__cmux_diff_viewer_wait/"
        guard rawPath.hasPrefix(prefix) else {
            try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: omitBody)
            return
        }

        let targetPath = "/" + String(rawPath.dropFirst(prefix.count))
        guard let file = try diffViewerHTTPAllowedFile(
            requestPath: targetPath,
            manifestCache: manifestCache
        ), file.mimeType == "text/html" else {
            try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: omitBody)
            return
        }

        guard waitForDiffViewerHTTPReplacement(file) else {
            try sendDiffViewerHTTPWaitTimedOut(fileDescriptor: fd, omitBody: omitBody)
            return
        }
        try sendDiffViewerHTTPFile(
            file,
            fileDescriptor: fd,
            port: port,
            omitBody: omitBody
        )
    }

    private func loadDiffViewerHTTPManifestFiles(
        token: String,
        rootDirectory: URL
    ) throws -> [String: DiffViewerAllowedFile] {
        let url = diffViewerHTTPManifestURL(token: token, rootDirectory: rootDirectory)
        let manifest = try JSONDecoder().decode(DiffViewerHTTPManifest.self, from: Data(contentsOf: url))
        guard manifest.token == token,
              !manifest.files.isEmpty,
              manifest.files.count <= 4096 else {
            throw CLIError(message: "Invalid diff viewer manifest")
        }

        let rootPath = rootDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        var files: [String: DiffViewerAllowedFile] = [:]
        for file in manifest.files {
            guard diffViewerHTTPIsValidRequestPath(file.requestPath),
                  diffViewerHTTPIsAllowedMimeType(file.mimeType),
                  diffViewerHTTPPathExtensionMatchesMimeType(path: file.requestPath, mimeType: file.mimeType) else {
                throw CLIError(message: "Invalid diff viewer manifest entry")
            }
            if let remoteURLString = file.remoteURL {
                guard file.mimeType == "text/x-diff",
                      file.filePath.isEmpty,
                      let remoteURL = URL(string: remoteURLString),
                      diffViewerHTTPIsAllowedRemotePatchURL(remoteURL),
                      files[file.requestPath] == nil else {
                    throw CLIError(message: "Invalid diff viewer remote manifest entry")
                }
                var normalizedFile = file
                normalizedFile.remoteURL = remoteURL.absoluteString
                files[file.requestPath] = normalizedFile
                continue
            }
            let fileURL = URL(fileURLWithPath: file.filePath, isDirectory: false)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard fileURL.path.hasPrefix(rootPath + "/") else {
                throw CLIError(message: "Diff viewer manifest file is outside the viewer directory")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: fileURL.path),
                  files[file.requestPath] == nil else {
                throw CLIError(message: "Invalid diff viewer manifest file")
            }

            var normalizedFile = file
            normalizedFile.filePath = fileURL.path
            files[file.requestPath] = normalizedFile
        }
        return files
    }

    private func diffViewerHTTPIsAllowedRemotePatchURL(_ url: URL) -> Bool {
        guard let canonicalURL = diffInputTrustedRemotePatchURL(url.absoluteString),
              canonicalURL.scheme == "https",
              canonicalURL.host?.lowercased() == "github.com",
              canonicalURL.path == url.path,
              canonicalURL.query == nil,
              canonicalURL.fragment == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        return canonicalURL.absoluteString == url.absoluteString
    }

    private func waitForDiffViewerHTTPReplacement(_ file: DiffViewerAllowedFile) -> Bool {
        let fileURL = URL(fileURLWithPath: file.filePath, isDirectory: false)
        guard diffViewerHTTPFileIsPending(fileURL) else { return true }

        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return false }

        let event = DispatchSemaphore(value: 0)
        let cleanup = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        source.setEventHandler {
            event.signal()
        }
        source.setCancelHandler {
            close(fd)
            cleanup.signal()
        }
        source.resume()
        defer {
            source.cancel()
            _ = cleanup.wait(timeout: .now() + 1)
        }
        let deadline = Date().addingTimeInterval(diffViewerHTTPReplacementWaitTimeout())
        while diffViewerHTTPFileIsPending(fileURL) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            let waitMilliseconds = max(1, Int((min(remaining, 1.0) * 1000).rounded(.up)))
            _ = event.wait(timeout: .now() + .milliseconds(waitMilliseconds))
        }
        return true
    }

    private func diffViewerHTTPReplacementWaitTimeout() -> TimeInterval {
        let defaultTimeout: TimeInterval = 120
        let key = "CMUX_DIFF_VIEWER_WAIT_TIMEOUT_SECONDS"
        guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = TimeInterval(raw),
              value.isFinite else {
            return defaultTimeout
        }
        return min(max(value, 0.05), 600)
    }

    private func sendDiffViewerHTTPWaitTimedOut(fileDescriptor fd: Int32, omitBody: Bool) throws {
        let title = CMUXDiffViewerLocalization.string(
            "diffViewer.loadingDiff",
            defaultValue: "Loading diff..."
        )
        let message = CMUXDiffViewerLocalization.string(
            "diffViewer.renderFailed",
            defaultValue: "Could not render this diff. Check the patch input and try again."
        )
        let body = Data(diffViewerHTTPStatusHTML(title: title, message: message).utf8)
        try sendDiffViewerHTTPResponse(
            fileDescriptor: fd,
            status: 504,
            reason: "Gateway Timeout",
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: body,
            omitBody: omitBody
        )
    }

    private func diffViewerHTTPStatusHTML(title: String, message: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(htmlEscaped(title))</title>
          <style>
            :root { color-scheme: light dark; }
            body {
              margin: 0;
              min-height: 100vh;
              display: grid;
              place-items: center;
              background: Canvas;
              color: CanvasText;
              font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
            }
            main {
              display: grid;
              gap: 10px;
              padding: 24px;
              max-width: 520px;
            }
            h1 {
              margin: 0;
              font-size: 14px;
              font-weight: 600;
            }
            p {
              margin: 0;
              opacity: 0.72;
              line-height: 1.45;
            }
          </style>
        </head>
        <body>
          <main>
            <h1>\(htmlEscaped(title))</h1>
            <p>\(htmlEscaped(message))</p>
          </main>
        </body>
        </html>
        """
    }

    private func diffViewerHTTPFileIsPending(_ fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192),
              !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.contains("data-cmux-diff-pending=\"true\"")
    }

    private func sendDiffViewerHTTPFile(
        _ file: DiffViewerAllowedFile,
        fileDescriptor fd: Int32,
        port: Int,
        omitBody: Bool
    ) throws {
        if let remoteURLString = file.remoteURL,
           let remoteURL = URL(string: remoteURLString),
           diffViewerHTTPIsAllowedRemotePatchURL(remoteURL) {
            try sendDiffViewerHTTPRemotePatch(
                remoteURL,
                fileDescriptor: fd,
                port: port,
                omitBody: omitBody
            )
            return
        }

        let fileURL = URL(fileURLWithPath: file.filePath, isDirectory: false)
        var info = stat()
        guard stat(fileURL.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: omitBody)
            return
        }

        var headers = diffViewerHTTPBaseHeaders(port: port)
        headers["Content-Type"] = diffViewerHTTPContentType(file.mimeType)
        headers["Content-Length"] = "\(info.st_size)"
        try sendDiffViewerHTTPHeader(
            fileDescriptor: fd,
            status: 200,
            reason: "OK",
            headers: headers
        )
        guard !omitBody else { return }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        while true {
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            try sendAllDiffViewerHTTPData(data, fileDescriptor: fd)
        }
    }

    private func sendDiffViewerHTTPRemotePatch(
        _ remoteURL: URL,
        fileDescriptor fd: Int32,
        port: Int,
        omitBody: Bool
    ) throws {
        var headers = diffViewerHTTPBaseHeaders(port: port)
        headers["Content-Type"] = diffViewerHTTPContentType("text/x-diff")
        headers["X-CMUX-Diff-Viewer-Remote"] = "github"

        if omitBody {
            try sendDiffViewerHTTPHeader(
                fileDescriptor: fd,
                status: 200,
                reason: "OK",
                headers: headers
            )
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "curl",
            "-fL",
            "--silent",
            "--show-error",
            "--max-time", "120",
            remoteURL.absoluteString
        ]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try sendDiffViewerHTTPResponse(
                fileDescriptor: fd,
                status: 502,
                reason: "Bad Gateway",
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data("502 Bad Gateway\n".utf8),
                omitBody: false
            )
            return
        }

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let handle = stdoutPipe.fileHandleForReading
        let firstChunk = try handle.read(upToCount: 64 * 1024) ?? Data()
        if firstChunk.isEmpty {
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try sendDiffViewerHTTPResponse(
                    fileDescriptor: fd,
                    status: 502,
                    reason: "Bad Gateway",
                    headers: ["Content-Type": "text/plain; charset=utf-8"],
                    body: Data("502 Bad Gateway\n".utf8),
                    omitBody: false
                )
                return
            }
            try sendDiffViewerHTTPHeader(
                fileDescriptor: fd,
                status: 200,
                reason: "OK",
                headers: headers
            )
            return
        }

        try sendDiffViewerHTTPHeader(
            fileDescriptor: fd,
            status: 200,
            reason: "OK",
            headers: headers
        )
        try sendAllDiffViewerHTTPData(firstChunk, fileDescriptor: fd)

        while true {
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            try sendAllDiffViewerHTTPData(data, fileDescriptor: fd)
        }
        process.waitUntilExit()
    }

    private func sendDiffViewerHTTPNotFound(fileDescriptor fd: Int32, omitBody: Bool) throws {
        try sendDiffViewerHTTPResponse(
            fileDescriptor: fd,
            status: 404,
            reason: "Not Found",
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data("404 Not Found\n".utf8),
            omitBody: omitBody
        )
    }

    private func sendDiffViewerHTTPResponse(
        fileDescriptor fd: Int32,
        status: Int,
        reason: String,
        headers: [String: String],
        body: Data,
        omitBody: Bool
    ) throws {
        var responseHeaders = diffViewerHTTPBaseHeaders(port: nil)
        for (key, value) in headers {
            responseHeaders[key] = value
        }
        responseHeaders["Content-Length"] = "\(body.count)"
        try sendDiffViewerHTTPHeader(
            fileDescriptor: fd,
            status: status,
            reason: reason,
            headers: responseHeaders
        )
        if !omitBody {
            try sendAllDiffViewerHTTPData(body, fileDescriptor: fd)
        }
    }

    private func sendDiffViewerHTTPHeader(
        fileDescriptor fd: Int32,
        status: Int,
        reason: String,
        headers: [String: String]
    ) throws {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        for key in headers.keys.sorted() {
            guard let value = headers[key] else { continue }
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"
        try sendAllDiffViewerHTTPData(Data(header.utf8), fileDescriptor: fd)
    }

    private func sendAllDiffViewerHTTPData(_ data: Data, fileDescriptor fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let sent = Darwin.send(
                    fd,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset,
                    0
                )
                if sent < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw CLIError(message: "Failed to write diff viewer response: \(posixErrorMessage(errno))")
                }
                if sent == 0 {
                    throw CLIError(message: "Failed to write diff viewer response")
                }
                offset += sent
            }
        }
    }

    private func diffViewerHTTPBaseHeaders(port: Int?) -> [String: String] {
        var headers: [String: String] = [
            "Cache-Control": "no-store",
            "Connection": "close",
            "Cross-Origin-Resource-Policy": "same-origin",
            "X-Content-Type-Options": "nosniff"
        ]
        if let port {
            headers["Origin-Agent-Cluster"] = "?1"
            headers["Referrer-Policy"] = "no-referrer"
            headers["X-CMUX-Diff-Viewer-Origin"] = "http://127.0.0.1:\(port)"
        }
        return headers
    }

    private func diffViewerHTTPContentType(_ mimeType: String) -> String {
        if mimeType.hasPrefix("text/") {
            return "\(mimeType); charset=utf-8"
        }
        return mimeType
    }

    private func diffViewerHTTPServerStateURL(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(".server.json", isDirectory: false)
    }

    private func diffViewerHTTPManifestURL(token: String, rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(".manifest-\(token).json", isDirectory: false)
    }

    private func diffViewerHTTPIsValidToken(_ token: String) -> Bool {
        guard (16...80).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
    }

    private func diffViewerHTTPIsValidRequestPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("//") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private func diffViewerHTTPIsAllowedMimeType(_ mimeType: String) -> Bool {
        mimeType == "text/html" || mimeType == "text/javascript" || mimeType == "text/x-diff"
    }

    private func diffViewerHTTPPathExtensionMatchesMimeType(path: String, mimeType: String) -> Bool {
        if mimeType == "text/html" {
            return path.hasSuffix(".html")
        }
        if mimeType == "text/javascript" {
            return path.hasSuffix(".mjs")
        }
        if mimeType == "text/x-diff" {
            return path.hasSuffix(".patch")
        }
        return false
    }

    private func posixErrorMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private func diffViewerAllowedFiles(
        pageURLs: [URL],
        assets: DiffViewerAssets,
        mapper: DiffViewerURLMapper,
        remotePatchURLsByPagePath: [String: URL] = [:]
    ) throws -> [DiffViewerAllowedFile] {
        var seen: Set<String> = []
        var files: [DiffViewerAllowedFile] = []

        func append(_ fileURL: URL, mimeType: String) throws {
            let standardizedPath = fileURL.standardizedFileURL.path
            guard seen.insert(standardizedPath).inserted else { return }
            files.append(try mapper.allowedFile(fileURL: fileURL, mimeType: mimeType))
        }

        for pageURL in pageURLs {
            try append(pageURL, mimeType: "text/html")
            let patchURL = diffViewerPatchFileURL(for: pageURL)
            if FileManager.default.fileExists(atPath: patchURL.path) {
                try append(patchURL, mimeType: "text/x-diff")
            } else if let remoteURL = remotePatchURLsByPagePath[pageURL.standardizedFileURL.path] {
                let standardizedPath = patchURL.standardizedFileURL.path
                guard seen.insert(standardizedPath).inserted else { continue }
                files.append(try mapper.allowedRemotePatchFile(fileURL: patchURL, remoteURL: remoteURL))
            }
        }
        for assetURL in assets.files {
            try append(assetURL, mimeType: "text/javascript")
        }
        return files
    }

    private func remotePatchURLMap(pageURL: URL, remoteURL: URL?) -> [String: URL] {
        guard let remoteURL else { return [:] }
        return [pageURL.standardizedFileURL.path: remoteURL]
    }

    private func diffViewerPatchFileURL(for viewerURL: URL) -> URL {
        viewerURL.deletingPathExtension().appendingPathExtension("patch")
    }

    private func diffViewerPatchURLString(for viewerURL: URL) -> String {
        "./\(viewerURL.deletingPathExtension().lastPathComponent).patch"
    }

    private func writeDiffViewerPatchSidecar(_ patch: String, for viewerURL: URL) throws {
        try patch.write(to: diffViewerPatchFileURL(for: viewerURL), atomically: true, encoding: .utf8)
    }

    private func writeDiffViewerHTML(
        patch: String,
        title: String,
        sourceLabel: String,
        externalURL: String?,
        remotePatchURL: URL? = nil,
        layout: String,
        appearance: DiffViewerAppearance,
        sourceOptions: [DiffViewerSourceOption],
        repoOptions: [DiffViewerSourceOption] = [],
        baseOptions: [DiffViewerSourceOption] = [],
        repoRoot: String? = nil,
        branchBaseRef: String? = nil
    ) throws -> URL {
        let directory = try diffViewerDirectory()

        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "diff-\(timestamp)-\(UUID().uuidString.prefix(8)).html"
        let viewerURL = directory.appendingPathComponent(filename, isDirectory: false)
        try writeDiffViewerHTML(
            to: viewerURL,
            patch: patch,
            title: title,
            sourceLabel: sourceLabel,
            externalURL: externalURL,
            remotePatchURL: remotePatchURL,
            layout: layout,
            appearance: appearance,
            sourceOptions: sourceOptions,
            repoOptions: repoOptions,
            baseOptions: baseOptions,
            repoRoot: repoRoot,
            branchBaseRef: branchBaseRef
        )
        return viewerURL
    }

    private func writeDiffViewerHTML(
        to viewerURL: URL,
        patch: String,
        title: String,
        sourceLabel: String,
        externalURL: String?,
        remotePatchURL: URL? = nil,
        layout: String,
        appearance: DiffViewerAppearance,
        sourceOptions: [DiffViewerSourceOption],
        repoOptions: [DiffViewerSourceOption] = [],
        baseOptions: [DiffViewerSourceOption] = [],
        repoRoot: String? = nil,
        branchBaseRef: String? = nil
    ) throws {
        if remotePatchURL == nil {
            try writeDiffViewerPatchSidecar(patch, for: viewerURL)
        }
        let labels = DiffViewerLabels.localized()
        var payload: [String: Any] = [
            "patchURL": diffViewerPatchURLString(for: viewerURL),
            "title": title,
            "sourceLabel": sourceLabel,
            "layout": layout,
            "appearance": appearance.jsonObject,
            "labels": labels.jsonObject,
            "sourceOptions": sourceOptions.map(\.jsonObject),
            "repoOptions": repoOptions.map(\.jsonObject),
            "baseOptions": baseOptions.map(\.jsonObject),
            "generatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let externalURL {
            payload["externalURL"] = externalURL
        }
        if let repoRoot {
            payload["repoRoot"] = repoRoot
        }
        if let branchBaseRef {
            payload["branchBaseRef"] = branchBaseRef
        }
        let assets = try ensureDiffViewerAssets(nextTo: viewerURL)
        let payloadLiteral = try jsonScriptLiteral(payload)
        let diffsModuleLiteral = try jsonStringLiteral(assets.diffsModuleURL)
        let treesModuleLiteral = try jsonStringLiteral(assets.treesModuleURL)
        let workerPoolModuleLiteral = try jsonStringLiteral(assets.workerPoolModuleURL)
        let workerModuleLiteral = try jsonStringLiteral(assets.workerModuleURL)
        let escapedTitle = htmlEscaped(title)
        let diffTargetLabel = htmlEscaped(labels["diffTarget"])
        let repoPathLabel = htmlEscaped(labels["repoPath"])
        let branchBaseLabel = htmlEscaped(labels["branchBase"])
        let jumpToFileLabel = htmlEscaped(labels["jumpToFile"])
        let openSourceURLLabel = htmlEscaped(labels["openSourceURL"])
        let hideFilesLabel = htmlEscaped(labels["hideFiles"])
        let switchToUnifiedDiffLabel = htmlEscaped(labels["switchToUnifiedDiff"])
        let optionsLabel = htmlEscaped(labels["options"])
        let changedFilesLabel = htmlEscaped(labels["changedFiles"])
        let filesLabel = htmlEscaped(labels["files"])
        let showFileSearchLabel = htmlEscaped(labels["showFileSearch"])
        let diffStatsLabel = htmlEscaped(labels["diffStats"])
        let additionsLabel = htmlEscaped(labels["additions"])
        let deletionsLabel = htmlEscaped(labels["deletions"])
        let diffViewerLabel = htmlEscaped(labels["diffViewer"])
        let loadingDiffLabel = htmlEscaped(labels["loadingDiff"])
        let htmlLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        let html = """
        <!doctype html>
        <html lang="\(htmlEscaped(htmlLanguage))">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedTitle)</title>
          <style>
            :root {
              color-scheme: light dark;
              --cmux-diff-bg-light: #fff;
              --cmux-diff-bg-dark: #000;
              --cmux-diff-fg-light: #000;
              --cmux-diff-fg-dark: #fff;
              --cmux-diff-selection-bg-light: #abd8ff;
              --cmux-diff-selection-bg-dark: #3f638b;
              --cmux-diff-ui-font-family: system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
              --cmux-diff-ui-font-size: 12px;
              --cmux-diff-ui-line-height: 16px;
              --cmux-diff-code-font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
              --cmux-diff-font-size: 10px;
              --cmux-diff-line-height: 20px;
              --cmux-diff-bg: var(--cmux-diff-bg-light);
              --cmux-diff-fg: var(--cmux-diff-fg-light);
              --cmux-diff-border: color-mix(in lab, var(--cmux-diff-fg) 12%, transparent);
              --cmux-diff-sidebar-bg: color-mix(in lab, var(--cmux-diff-bg) 98%, var(--cmux-diff-fg));
              --cmux-diff-muted-bg: color-mix(in lab, var(--cmux-diff-fg) 8%, transparent);
              --cmux-diff-hover-bg: color-mix(in lab, var(--cmux-diff-fg) 10%, transparent);
              --cmux-diff-accent: light-dark(#0a84ff, #7ab7ff);
              background: var(--cmux-diff-bg);
              color: var(--cmux-diff-fg);
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --cmux-diff-bg: var(--cmux-diff-bg-dark);
                --cmux-diff-fg: var(--cmux-diff-fg-dark);
              }
            }
            * {
              box-sizing: border-box;
            }
            html,
            body {
              height: 100%;
              overflow: hidden;
            }
            body {
              margin: 0;
              height: 100vh;
              min-height: 0;
              background: var(--cmux-diff-bg);
              color: var(--cmux-diff-fg);
              display: flex;
              flex-direction: column;
              overflow: hidden;
              font-family: var(--cmux-diff-ui-font-family);
              font-size: var(--cmux-diff-ui-font-size);
              line-height: var(--cmux-diff-ui-line-height);
            }
            #app {
              height: 100vh;
              min-height: 0;
              display: grid;
              grid-template-rows: auto minmax(0, 1fr);
              overflow: hidden;
              overscroll-behavior: contain;
              contain: strict;
              background: inherit;
              color: inherit;
            }
            #toolbar {
              position: relative;
              flex: 0 0 auto;
              display: flex;
              align-items: center;
              gap: 7px;
              min-height: 32px;
              padding: 3px 8px;
              border-bottom: 1px solid color-mix(in lab, var(--cmux-diff-fg) 14%, transparent);
              background: color-mix(in lab, var(--cmux-diff-bg) 98%, var(--cmux-diff-fg));
              color: color-mix(in lab, var(--cmux-diff-fg) 76%, var(--cmux-diff-bg));
              z-index: 50;
            }
            .toolbar-left,
            .toolbar-middle,
            .toolbar-actions {
              display: flex;
              align-items: center;
              gap: 6px;
              min-width: 0;
            }
            .toolbar-left {
              flex: 0 1 36%;
            }
            .toolbar-middle {
              flex: 1 1 auto;
              justify-content: center;
            }
            .toolbar-actions {
              flex: 0 0 auto;
            }
            #source-select,
            #repo-select,
            #base-select,
            #jump-select {
              appearance: none;
              height: 24px;
              min-width: 118px;
              max-width: min(30vw, 320px);
              padding: 0 24px 0 9px;
              border: 1px solid transparent;
              border-radius: 6px;
              background:
                linear-gradient(45deg, transparent 50%, currentColor 50%) right 11px center / 4px 4px no-repeat,
                linear-gradient(135deg, currentColor 50%, transparent 50%) right 7px center / 4px 4px no-repeat,
                color-mix(in lab, var(--cmux-diff-fg) 7%, transparent);
              color: inherit;
              font: inherit;
            }
            #source-select:hover,
            #repo-select:hover,
            #base-select:hover,
            #jump-select:hover {
              border-color: color-mix(in lab, var(--cmux-diff-fg) 24%, transparent);
              background-color: color-mix(in lab, var(--cmux-diff-fg) 10%, transparent);
            }
            #source-select[hidden],
            #repo-select[hidden],
            #base-select[hidden],
            #jump-select[hidden] {
              display: none;
            }
            #jump-select {
              min-width: min(250px, 30vw);
            }
            #repo-select {
              min-width: 132px;
              max-width: min(26vw, 320px);
            }
            #base-select {
              min-width: 120px;
              max-width: min(22vw, 260px);
            }
            #source-select:focus,
            #repo-select:focus,
            #base-select:focus,
            #jump-select:focus,
            .toolbar-icon:focus-visible,
            .menu-item:focus-visible,
            .file-entry:focus-visible {
              outline: 2px solid color-mix(in lab, var(--cmux-diff-fg) 36%, transparent);
              outline-offset: 1px;
            }
            #source-detail {
              min-width: 0;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
              color: color-mix(in lab, var(--cmux-diff-fg) 52%, var(--cmux-diff-bg));
            }
            .toolbar-icon {
              width: 28px;
              height: 26px;
              display: inline-flex;
              align-items: center;
              justify-content: center;
              border: 1px solid transparent;
              border-radius: 6px;
              background: transparent;
              color: color-mix(in lab, var(--cmux-diff-fg) 60%, var(--cmux-diff-bg));
              padding: 0;
              cursor: pointer;
            }
            .toolbar-icon:hover,
            .toolbar-icon[aria-expanded="true"] {
              border-color: color-mix(in lab, var(--cmux-diff-fg) 14%, transparent);
              background: color-mix(in lab, var(--cmux-diff-fg) 9%, transparent);
              color: var(--cmux-diff-fg);
            }
            .toolbar-icon[aria-pressed="true"] {
              color: color-mix(in lab, var(--cmux-diff-fg) 78%, var(--cmux-diff-bg));
            }
            .toolbar-icon[hidden] {
              display: none;
            }
            .toolbar-icon svg,
            .menu-item svg {
              width: 16px;
              height: 16px;
              display: block;
              fill: none;
              stroke: currentColor;
              stroke-width: 1.75;
              stroke-linecap: round;
              stroke-linejoin: round;
            }
            #layout-toggle svg [data-accent] {
              stroke: light-dark(#0a84ff, #7ab7ff);
            }
            #options-menu {
              position: absolute;
              top: calc(100% + 7px);
              right: 10px;
              min-width: 246px;
              padding: 8px;
              border: 1px solid color-mix(in lab, var(--cmux-diff-fg) 13%, transparent);
              border-radius: 8px;
              background: color-mix(in lab, var(--cmux-diff-bg) 94%, var(--cmux-diff-fg));
              box-shadow: 0 16px 34px color-mix(in lab, #000 28%, transparent);
              z-index: 100;
            }
            #options-menu[hidden] {
              display: none;
            }
            .menu-separator {
              height: 1px;
              margin: 7px 6px;
              background: color-mix(in lab, var(--cmux-diff-fg) 12%, transparent);
            }
            .menu-item {
              width: 100%;
              min-height: 31px;
              display: grid;
              grid-template-columns: 22px minmax(0, 1fr) 18px;
              align-items: center;
              gap: 10px;
              border: 0;
              border-radius: 6px;
              background: transparent;
              color: color-mix(in lab, var(--cmux-diff-fg) 86%, var(--cmux-diff-bg));
              font: inherit;
              text-align: left;
              padding: 0 7px;
            }
            .menu-item:hover:not(:disabled) {
              background: color-mix(in lab, var(--cmux-diff-fg) 10%, transparent);
              color: var(--cmux-diff-fg);
            }
            .menu-segment {
              cursor: default;
            }
            .menu-segment:hover {
              background: transparent;
            }
            .menu-segment-controls {
              display: inline-flex;
              align-items: center;
              gap: 2px;
              justify-self: end;
              padding: 2px;
              border-radius: 7px;
              background: color-mix(in lab, var(--cmux-diff-bg) 82%, var(--cmux-diff-fg));
            }
            .segment-button {
              width: 27px;
              height: 24px;
              display: inline-flex;
              align-items: center;
              justify-content: center;
              border: 0;
              border-radius: 5px;
              background: transparent;
              color: color-mix(in lab, var(--cmux-diff-fg) 62%, var(--cmux-diff-bg));
              padding: 0;
            }
            .segment-button:hover,
            .segment-button[aria-pressed="true"] {
              background: color-mix(in lab, var(--cmux-diff-fg) 12%, transparent);
              color: var(--cmux-diff-fg);
            }
            .menu-item:disabled {
              color: color-mix(in lab, var(--cmux-diff-fg) 36%, var(--cmux-diff-bg));
            }
            .menu-label {
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .menu-check {
              justify-self: end;
            }
            #content {
              --cmux-diff-files-width: clamp(190px, 22vw, 252px);
              position: relative;
              flex: 1 1 auto;
              min-height: 0;
              min-width: 0;
              display: grid;
              grid-template-columns: minmax(0, 1fr) var(--cmux-diff-files-width);
              grid-template-rows: minmax(0, 1fr);
              grid-template-areas: "viewer files";
              overflow: hidden;
              overscroll-behavior: contain;
              contain: strict;
              background: inherit;
            }
            body[data-files-hidden="true"] #content {
              grid-template-columns: minmax(0, 1fr) 0;
            }
            #files-sidebar {
              grid-area: files;
              position: relative;
              width: 100%;
              height: 100%;
              min-height: 0;
              min-width: 0;
              display: flex;
              flex-direction: column;
              overflow: hidden;
              border-left: 1px solid var(--cmux-diff-border);
              background: color-mix(in lab, var(--cmux-diff-bg) 99%, var(--cmux-diff-fg));
              contain: strict;
              opacity: 1;
              transition: opacity 100ms ease, visibility 0s linear 0s;
            }
            body[data-files-hidden="true"] #files-sidebar {
              opacity: 0;
              pointer-events: none;
              visibility: hidden;
              transition: opacity 100ms ease, visibility 0s linear 100ms;
            }
            #files-header {
              position: relative;
              z-index: 1;
              display: flex;
              align-items: center;
              justify-content: space-between;
              min-height: 30px;
              gap: 8px;
              padding: 0 7px 0 10px;
              border-bottom: 1px solid color-mix(in lab, var(--cmux-diff-fg) 10%, transparent);
              background: color-mix(in lab, var(--cmux-diff-bg) 99%, var(--cmux-diff-fg));
              color: color-mix(in lab, var(--cmux-diff-fg) 52%, var(--cmux-diff-bg));
            }
            #files-title {
              display: inline-flex;
              align-items: center;
              gap: 6px;
              min-width: 0;
            }
            #files-header-actions {
              display: inline-flex;
              align-items: center;
              gap: 2px;
              flex: 0 0 auto;
            }
            #file-search-toggle,
            #file-collapse-toggle {
              width: 24px;
              height: 24px;
              flex: 0 0 auto;
              display: inline-flex;
              align-items: center;
              justify-content: center;
              border: 0;
              border-radius: 5px;
              background: transparent;
              color: color-mix(in lab, var(--cmux-diff-fg) 54%, var(--cmux-diff-bg));
              padding: 0;
            }
            #file-search-toggle:hover,
            #file-search-toggle[aria-pressed="true"],
            #file-collapse-toggle:hover {
              background: var(--cmux-diff-hover-bg);
              color: var(--cmux-diff-fg);
            }
            #file-search-toggle svg,
            #file-collapse-toggle svg {
              width: 15px;
              height: 15px;
              fill: none;
              stroke: currentColor;
              stroke-width: 1.75;
              stroke-linecap: round;
              stroke-linejoin: round;
            }
            #file-list {
              flex: 1 1 auto;
              min-height: 0;
              overflow: hidden;
              padding: 6px 4px 6px 6px;
              --trees-bg-override: var(--cmux-diff-sidebar-bg);
              --trees-fg-override: color-mix(in lab, var(--cmux-diff-fg) 72%, var(--cmux-diff-bg));
              --trees-fg-muted-override: color-mix(in lab, var(--cmux-diff-fg) 48%, var(--cmux-diff-bg));
              --trees-bg-muted-override: var(--cmux-diff-hover-bg);
              --trees-selected-bg-override: color-mix(in lab, var(--cmux-diff-fg) 11%, transparent);
              --trees-selected-fg-override: var(--cmux-diff-fg);
              --trees-selected-focused-border-color-override: transparent;
              --trees-border-color-override: var(--cmux-diff-border);
              --trees-focus-ring-color-override: color-mix(in lab, var(--cmux-diff-accent) 72%, transparent);
              --trees-font-family-override: var(--cmux-diff-ui-font-family);
              --trees-font-size-override: var(--cmux-diff-ui-font-size);
              --trees-font-weight-semibold-override: 500;
              --trees-density-override: 0.78;
              --trees-border-radius-override: 5px;
              --trees-item-padding-x-override: 7px;
              --trees-item-margin-x-override: 0;
              --trees-padding-inline-override: 0;
              --trees-search-bg-override: color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg));
              --trees-status-added-override: light-dark(#257a3e, #8fd88f);
              --trees-status-modified-override: var(--cmux-diff-accent);
              --trees-status-renamed-override: light-dark(#a26300, #ffd166);
              --trees-status-deleted-override: light-dark(#b42318, #ff8a80);
            }
            #file-list file-tree-container {
              width: 100%;
              height: 100%;
            }
            #files-footer {
              flex: 0 0 auto;
              padding: 7px 10px 8px;
              border-top: 1px solid color-mix(in lab, var(--cmux-diff-fg) 10%, transparent);
              background: color-mix(in lab, var(--cmux-diff-bg) 97%, var(--cmux-diff-fg));
            }
            .stats-row {
              display: flex;
              align-items: center;
              justify-content: space-between;
              gap: 10px;
              min-height: 19px;
              color: color-mix(in lab, var(--cmux-diff-fg) 54%, var(--cmux-diff-bg));
            }
            .stats-row strong {
              color: color-mix(in lab, var(--cmux-diff-fg) 82%, var(--cmux-diff-bg));
              font-weight: 600;
            }
            .file-entry {
              width: 100%;
              min-height: 30px;
              display: grid;
              grid-template-columns: 18px minmax(0, 1fr) auto;
              align-items: center;
              gap: 8px;
              border: 0;
              border-radius: 6px;
              background: transparent;
              color: inherit;
              font: inherit;
              text-align: left;
              padding: 3px 7px;
            }
            .file-entry:hover,
            .file-entry[aria-current="true"] {
              background: color-mix(in lab, var(--cmux-diff-fg) 9%, transparent);
            }
            .file-status {
              width: 17px;
              height: 17px;
              border: 1px solid currentColor;
              border-radius: 5px;
              display: inline-flex;
              align-items: center;
              justify-content: center;
              font-size: 9px;
              line-height: 1;
              color: color-mix(in lab, var(--cmux-diff-fg) 62%, var(--cmux-diff-bg));
            }
            .file-name {
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .file-stats {
              display: inline-flex;
              gap: 5px;
              color: color-mix(in lab, var(--cmux-diff-fg) 50%, var(--cmux-diff-bg));
            }
            .stat-add {
              color: light-dark(#257a3e, #8fd88f);
            }
            .stat-del {
              color: light-dark(#b42318, #ff8a80);
            }
            #viewer {
              --diffs-font-family: var(--cmux-diff-code-font-family);
              --diffs-header-font-family: var(--cmux-diff-ui-font-family);
              --diffs-font-size: var(--cmux-diff-font-size);
              --diffs-line-height: var(--cmux-diff-line-height);
              --diffs-bg-selection-override: light-dark(var(--cmux-diff-selection-bg-light), var(--cmux-diff-selection-bg-dark));
              grid-area: viewer;
              width: 100%;
              height: 100%;
              min-height: 0;
              min-width: 0;
              position: relative;
              overflow-y: auto;
              overflow-x: clip;
              overscroll-behavior: contain;
              overflow-anchor: none;
              contain: strict;
              will-change: scroll-position;
              border-bottom: 1px solid var(--cmux-diff-border);
              background: inherit;
            }
            @media (max-width: 520px) {
              #content,
              body[data-files-hidden="true"] #content {
                grid-template-columns: minmax(0, 1fr);
                grid-template-areas: "viewer";
              }
              #files-sidebar {
                display: none;
              }
            }
            @media (prefers-reduced-motion: reduce) {
              #files-sidebar {
                transition: none;
              }
            }
            #viewer diffs-container {
              --diffs-font-family: var(--cmux-diff-code-font-family);
              --diffs-header-font-family: var(--cmux-diff-ui-font-family);
              --diffs-font-size: var(--cmux-diff-font-size);
              --diffs-line-height: var(--cmux-diff-line-height);
              --diffs-bg-selection-override: light-dark(var(--cmux-diff-selection-bg-light), var(--cmux-diff-selection-bg-dark));
              display: block;
              overflow: clip;
              contain: layout paint style;
              box-shadow: 0 -1px 0 var(--cmux-diff-border), 0 1px 0 var(--cmux-diff-border);
            }
            #status {
              padding: 16px;
              font-family: var(--cmux-diff-ui-font-family);
              font-size: 13px;
              line-height: var(--cmux-diff-ui-line-height);
              color: color-mix(in lab, var(--cmux-diff-fg) 70%, var(--cmux-diff-bg));
            }
            #status[data-error="true"] {
              color: light-dark(#b42318, #ff8a80);
            }
          </style>
        </head>
        <body data-files-hidden="false">
          <div id="app">
            <header id="toolbar">
              <div class="toolbar-left">
                <select id="source-select" aria-label="\(diffTargetLabel)" hidden></select>
                <select id="repo-select" aria-label="\(repoPathLabel)" hidden></select>
                <select id="base-select" aria-label="\(branchBaseLabel)" hidden></select>
                <span id="source-detail"></span>
              </div>
              <div class="toolbar-middle">
                <select id="jump-select" aria-label="\(jumpToFileLabel)" hidden></select>
              </div>
              <div class="toolbar-actions">
                <a id="external-link" class="toolbar-icon" target="_blank" rel="noreferrer" title="\(openSourceURLLabel)" aria-label="\(openSourceURLLabel)" hidden></a>
                <button id="files-toggle" class="toolbar-icon" type="button" title="\(hideFilesLabel)" aria-label="\(hideFilesLabel)" aria-pressed="true"></button>
                <button id="layout-toggle" class="toolbar-icon" type="button" title="\(switchToUnifiedDiffLabel)" aria-label="\(switchToUnifiedDiffLabel)"></button>
                <button id="options-button" class="toolbar-icon" type="button" title="\(optionsLabel)" aria-label="\(optionsLabel)" aria-expanded="false" aria-haspopup="menu"></button>
              </div>
              <div id="options-menu" role="menu" hidden></div>
            </header>
            <section id="content">
              <aside id="files-sidebar" aria-label="\(changedFilesLabel)">
                <div id="files-header">
                  <span id="files-title"><span>\(filesLabel)</span><span id="files-count"></span></span>
                  <span id="files-header-actions">
                    <button id="file-search-toggle" type="button" title="\(showFileSearchLabel)" aria-label="\(showFileSearchLabel)" aria-pressed="false"></button>
                    <button id="file-collapse-toggle" type="button" title="\(hideFilesLabel)" aria-label="\(hideFilesLabel)"></button>
                  </span>
                </div>
                <div id="file-list"></div>
                <div id="files-footer" aria-label="\(diffStatsLabel)">
                  <div class="stats-row"><span>\(filesLabel)</span><strong id="stats-files">0</strong></div>
                  <div class="stats-row"><span>\(additionsLabel)</span><strong id="stats-added" class="stat-add">+0</strong></div>
                  <div class="stats-row"><span>\(deletionsLabel)</span><strong id="stats-deleted" class="stat-del">-0</strong></div>
                </div>
              </aside>
              <main id="viewer" aria-label="\(diffViewerLabel)">
                <div id="status">\(loadingDiffLabel)</div>
              </main>
            </section>
          </div>
          <script type="module">
            const DIFFS_MODULE_URL = \(diffsModuleLiteral);
            const TREES_MODULE_URL = \(treesModuleLiteral);
            const WORKER_POOL_MODULE_URL = \(workerPoolModuleLiteral);
            const DIFF_WORKER_URL = \(workerModuleLiteral);
            const payload = \(payloadLiteral);
            const labels = payload.labels ?? {};
            const viewerElement = document.getElementById("viewer");
            const status = document.getElementById("status");
            const toolbar = document.getElementById("toolbar");
            const sourceSelect = document.getElementById("source-select");
            const repoSelect = document.getElementById("repo-select");
            const baseSelect = document.getElementById("base-select");
            const sourceDetail = document.getElementById("source-detail");
            const jumpSelect = document.getElementById("jump-select");
            const externalLink = document.getElementById("external-link");
            const filesToggle = document.getElementById("files-toggle");
            const layoutToggle = document.getElementById("layout-toggle");
            const optionsButton = document.getElementById("options-button");
            const optionsMenu = document.getElementById("options-menu");
            const filesSidebar = document.getElementById("files-sidebar");
            const fileList = document.getElementById("file-list");
            const filesCount = document.getElementById("files-count");
            const fileSearchToggle = document.getElementById("file-search-toggle");
            const fileCollapseToggle = document.getElementById("file-collapse-toggle");
            const statsFiles = document.getElementById("stats-files");
            const statsAdded = document.getElementById("stats-added");
            const statsDeleted = document.getElementById("stats-deleted");
            const label = (key) => labels[key] ?? key;
            const appState = {
              layout: payload.layout === "unified" ? "unified" : "split",
              filesVisible: true,
              wordWrap: false,
              collapsed: false,
              expandUnchanged: false,
              showBackgrounds: true,
              lineNumbers: true,
              diffIndicators: "bars",
              wordDiffs: false,
              fileSearchOpen: false,
            };
            let codeView;
            let workerPool;
            let fileTree;
            const diffItems = [];
            const codeViewItems = [];
            const diffItemById = new Map();
            let codeViewItemIds = new Set();
            let fileTreeSource = null;
            let currentTreeSource = null;
            let fileTreeStatsByPath = new Map();
            let patchTextPromise = { value: null };
            let activeFileId = "";
            let activeTreePath = "";
            let suppressTreeSelectionChange = false;
            let itemIdByTreePath = new Map();
            let treePathByItemId = new Map();
            document.title = payload.title;
            applyViewerAppearance(payload.appearance);
            setupToolbar();
            setupSourceSelector(payload.sourceOptions ?? []);
            setupNavigationSelector(repoSelect, payload.repoOptions ?? [], payload.repoRoot ?? "", label("repoPath"));
            setupNavigationSelector(baseSelect, payload.baseOptions ?? [], payload.branchBaseRef ?? "", label("branchBase"));
            const scheduleRender = globalThis.queueMicrotask ?? ((callback) => setTimeout(callback, 0));
            scheduleRender(() => {
              renderDiff().catch((error) => {
                console.error("cmux diff viewer render failed", error);
                status.dataset.error = "true";
                status.textContent = label("renderFailed");
              });
            });

            async function renderDiff() {
              status.textContent = label("loadingRenderer");
              const {
                CodeView,
                getFiletypeFromFileName,
                parsePatchFiles,
                preloadHighlighter,
                processFile,
                registerCustomTheme,
              } = await import(DIFFS_MODULE_URL);
              const treesModule = await import(TREES_MODULE_URL)
                .catch((error) => {
                  console.warn("cmux diff file tree import failed", error);
                  return null;
                });

              registerGhosttyTheme(registerCustomTheme, payload.appearance.themes.light);
              registerGhosttyTheme(registerCustomTheme, payload.appearance.themes.dark);
              status.textContent = label("parsingDiff");
              setWorkerPoolStatus("loading");
              workerPool = await createCodeViewWorkerPool();
              setupJumpSelector(diffItems);
              updateToolbarState();
              window.__cmuxDiffViewer = { codeView, items: diffItems, state: appState, workerPool };
              observeWorkerPool(workerPool);
              const workerInitialization = workerPool?.initialize?.();
              workerInitialization
                ?.then?.(() => recordWorkerPoolStats(workerPool?.getStats?.()))
                ?.catch?.((error) => console.warn("cmux diff worker pool initialization failed", error));
              window.addEventListener("pagehide", () => workerPool?.terminate?.(), { once: true });

              await streamPatchIntoCodeView({
                CodeView,
                parsePatchFiles,
                processFile,
                treesModule,
              });

              if (diffItems.length === 0) {
                throw new Error(label("noFileDiffs"));
              }

              if (!workerPool) {
                preloadDiffHighlighter(payload.appearance, codeViewItems.length > 0 ? codeViewItems : diffItems, getFiletypeFromFileName, preloadHighlighter)
                  .catch((error) => console.warn("cmux diff highlighter preload failed", error));
              }
            }

            async function createCodeViewWorkerPool() {
              if (typeof Worker === "undefined") {
                return null;
              }
              try {
                const workerPoolModule = await import(WORKER_POOL_MODULE_URL);
                registerGhosttyTheme(workerPoolModule.registerCustomTheme, payload.appearance.themes.light);
                registerGhosttyTheme(workerPoolModule.registerCustomTheme, payload.appearance.themes.dark);
                const workerURL = new URL(DIFF_WORKER_URL, window.location.href).href;
                return workerPoolModule.createDiffWorkerPool({
                  workerURL,
                  highlighterOptions: workerHighlighterOptions(),
                }) ?? null;
              } catch (error) {
                console.warn("cmux diff worker pool unavailable; falling back to main-thread highlighting", error);
                return null;
              }
            }

            function observeWorkerPool(pool) {
              if (!pool) {
                setWorkerPoolStatus("fallback");
                return;
              }
              setWorkerPoolStatus("enabled");
              recordWorkerPoolStats(pool.getStats?.());
              const unsubscribe = pool.subscribeToStatChanges?.((stats) => {
                recordWorkerPoolStats(stats);
              });
              if (typeof unsubscribe === "function") {
                window.addEventListener("pagehide", unsubscribe, { once: true });
              }
            }

            function setWorkerPoolStatus(status) {
              document.body.dataset.workerPool = status;
            }

            function recordWorkerPoolStats(stats) {
              if (!stats || typeof stats !== "object") {
                return;
              }
              if (typeof stats.managerState === "string") {
                document.body.dataset.workerPoolState = stats.managerState;
              }
              if (Number.isFinite(stats.totalWorkers)) {
                document.body.dataset.workerPoolWorkers = String(stats.totalWorkers);
              }
              if (typeof stats.workersFailed === "boolean") {
                document.body.dataset.workerPoolFailed = String(stats.workersFailed);
              }
            }

            function workerHighlighterOptions() {
              return {
                theme: payload.appearance.theme,
                preferredHighlighter: "shiki-wasm",
                lineDiffType: appState.wordDiffs ? "word" : "none",
                maxLineDiffLength: 1000,
                tokenizeMaxLineLength: 1000,
                useTokenTransformer: false,
              };
            }

            const commitMetadataPattern = /^From\\s+([a-f0-9]+)\\s/im;

            function commitMetadataLabel(metadata, index) {
              const match = metadata?.match(commitMetadataPattern);
              if (match?.[1]) {
                return new TextDecoder().decode(new TextEncoder().encode(match[1].slice(0, 5)));
              }
              return `Commit ${index + 1}`;
            }

            async function streamPatchIntoCodeView({ CodeView, parsePatchFiles, processFile, treesModule }) {
              const diffModel = createStreamingDiffModel();
              const navigationRefreshState = {
                dirtyCount: 0,
                lastRefreshAt: 0,
                timeout: 0,
                treesModule: null,
              };
              const streamMetrics = {
                startedAt: performance.now(),
                completedAt: 0,
                flushCount: 0,
                maxBatchSize: 0,
                treeRefreshCount: 0,
              };
              let lastYieldAt = performance.now();
              let lastFlushAt = performance.now();
              let firstRender = true;
              const batchConfig = {
                initialBatchSize: getInitialFileTreeRowCount(),
                incrementalBatchSize: 25,
                initialMaxWait: 500,
                incrementalMaxWait: 100,
              };

              function makeItem(fileDiff, patchPrefix) {
                const result = appendFileDiffToModel(diffModel, fileDiff, patchPrefix);
                if (result?.renamedItem) {
                  applyRenamedDiffItem(result.renamedItem);
                }
                return result?.item;
              }

              function appendFileDiffToModel(model, fileDiff, patchPrefix) {
                if (!fileDiff) {
                  return null;
                }
                const path = fileName(fileDiff);
                const treePath = patchPrefix == null ? path : `${patchPrefix}/${path}`;
                const previousState = path.length === 0 ? undefined : model.pathStateByTreePath.get(treePath);
                const renamedItem = previousState == null ? undefined : moveCurrentPathItemToPrevious(model, treePath, previousState);
                const stats = fileStats(fileDiff);
                const itemId = model.itemIdToFile.has(treePath) ? uniqueDiffItemId(model, `${treePath}?2`) : treePath;
                const item = {
                  id: itemId,
                  type: "diff",
                  fileDiff,
                  version: 0,
                };
                const fileOrder = model.items.length;
                model.fileIndex += 1;
                model.items.push(item);
                model.pendingItems.push(item);
                model.pendingItemById.set(item.id, item);
                model.itemIdToFile.set(item.id, { fileOrder, path });
                model.itemIdByTreePath.set(treePath, item.id);
                model.treePathByItemId.set(item.id, treePath);
                model.diffStats.addedLines += stats.added;
                model.diffStats.deletedLines += stats.deleted;
                model.diffStats.fileCount += 1;
                model.diffStats.totalLinesOfCode += fileDiff.unifiedLineCount ?? fileDiff.splitLineCount ?? 0;
                const previousStats = model.statsByPath.get(treePath);
                model.statsByPath.set(treePath, stats);
                if (previousState != null && !sameFileStats(previousStats, stats)) {
                  model.pendingStatsChanged = true;
                }
                if (path.length > 0) {
                  if (previousState == null) {
                    model.paths.push(treePath);
                  }
                  model.pathToItemId.set(treePath, item.id);
                  updateGitStatusForPath(model, treePath, fileDiff.type, previousState?.sawDeleted === true);
                  model.pathStateByTreePath.set(treePath, {
                    currentItem: item,
                    currentItemId: item.id,
                    currentType: fileDiff.type,
                    fileOrder,
                    sawDeleted: previousState?.sawDeleted === true || fileDiff.type === "deleted",
                  });
                }
                return { item, renamedItem };
              }

              function moveCurrentPathItemToPrevious(model, treePath, state) {
                const oldId = state.currentItemId;
                const suffix = state.currentType === "deleted" ? "?deleted" : "?previous";
                const newId = uniqueDiffItemId(model, `${treePath}${suffix}`);
                state.currentItem.id = newId;
                state.currentItemId = newId;
                if (model.itemIdToFile.has(oldId)) {
                  const itemMetadata = model.itemIdToFile.get(oldId);
                  model.itemIdToFile.delete(oldId);
                  model.itemIdToFile.set(newId, itemMetadata);
                }
                if (model.treePathByItemId.has(oldId)) {
                  model.treePathByItemId.delete(oldId);
                  model.treePathByItemId.set(newId, treePath);
                }
                if (model.pendingItemById.has(oldId)) {
                  const pendingItem = model.pendingItemById.get(oldId);
                  model.pendingItemById.delete(oldId);
                  model.pendingItemById.set(newId, pendingItem);
                  return undefined;
                }
                return { oldId, newId };
              }

              function uniqueDiffItemId(model, baseId) {
                if (!model.itemIdToFile.has(baseId)) {
                  return baseId;
                }
                let suffix = model.nextCollisionSuffixByBase.get(baseId) ?? 2;
                let nextId = `${baseId}-${suffix}`;
                while (model.itemIdToFile.has(nextId)) {
                  suffix += 1;
                  nextId = `${baseId}-${suffix}`;
                }
                model.nextCollisionSuffixByBase.set(baseId, suffix + 1);
                return nextId;
              }

              function updateGitStatusForPath(model, treePath, changeType, sawDeleted) {
                if (sawDeleted && changeType !== "deleted") {
                  if (model.gitStatusByPath.delete(treePath)) {
                    markGitStatusRemoved(model, treePath);
                  }
                  return;
                }
                const status = gitStatusType(changeType);
                if (status === "modified") {
                  if (model.gitStatusByPath.delete(treePath)) {
                    markGitStatusRemoved(model, treePath);
                  }
                  return;
                }
                const current = model.gitStatusByPath.get(treePath);
                if (current?.status === status) {
                  return;
                }
                const entry = { path: treePath, status };
                model.gitStatusByPath.set(treePath, entry);
                model.pendingGitStatusRemovePaths.delete(treePath);
                model.pendingGitStatusSetByPath.set(treePath, entry);
              }

              function markGitStatusRemoved(model, treePath) {
                model.pendingGitStatusSetByPath.delete(treePath);
                model.pendingGitStatusRemovePaths.add(treePath);
              }

              function applyRenamedDiffItem(rename) {
                if (codeViewItemIds.delete(rename.oldId)) {
                  codeViewItemIds.add(rename.newId);
                }
                if (diffItemById.has(rename.oldId)) {
                  const item = diffItemById.get(rename.oldId);
                  diffItemById.delete(rename.oldId);
                  diffItemById.set(rename.newId, item);
                }
                renameJumpOption(rename.oldId, rename.newId);
                codeView?.updateItemId?.(rename.oldId, rename.newId);
              }

              async function enqueueFileDiff(fileDiff, patchPrefix) {
                const item = makeItem(fileDiff, patchPrefix);
                if (!item) {
                  return;
                }
                await maybeFlushPendingItems(false);
              }

              async function maybeFlushPendingItems(force) {
                if (diffModel.pendingItems.length === 0) {
                  return;
                }
                const now = performance.now();
                if (!force &&
                    firstRender &&
                    now - lastYieldAt >= 8 &&
                    diffModel.pendingItems.length < batchConfig.initialBatchSize &&
                    now - lastFlushAt < batchConfig.initialMaxWait) {
                  await yieldToNextFrame();
                  lastYieldAt = performance.now();
                  return;
                }
                const batchSize = firstRender ? batchConfig.initialBatchSize : batchConfig.incrementalBatchSize;
                const maxWait = firstRender ? batchConfig.initialMaxWait : batchConfig.incrementalMaxWait;
                const shouldFlush = force ||
                  diffModel.pendingItems.length >= batchSize ||
                  now - lastFlushAt >= maxWait;
                if (shouldFlush) {
                  flushPendingItems();
                  await yieldToNextFrame();
                  lastYieldAt = performance.now();
                  return;
                }
              }

              function flushPendingItems() {
                if (diffModel.pendingItems.length === 0) {
                  return;
                }
                const batch = diffModel.pendingItems.splice(0, diffModel.pendingItems.length);
                diffModel.pendingItemById.clear();
                const codeBatch = batch;
                const hadCodeItems = codeViewItems.length > 0;
                diffItems.push(...batch);
                for (const item of batch) {
                  diffItemById.set(item.id, item);
                }
                if (codeBatch.length > 0) {
                  codeViewItems.push(...codeBatch);
                  for (const item of codeBatch) {
                    codeViewItemIds.add(item.id);
                  }
                  if (!codeView) {
                    codeView = new CodeView(codeViewOptions(), workerPool ?? undefined);
                    codeView.setup(viewerElement);
                    codeView.setItems(codeViewItems);
                    codeView.render(true);
                    window.__cmuxDiffViewer.codeView = codeView;
                  } else {
                    codeView.addItems(codeBatch);
                  }
                }
                appendJumpOptions(batch);
                scheduleNavigationRefresh(treesModule, false, batch.length);
                streamMetrics.flushCount += 1;
                streamMetrics.maxBatchSize = Math.max(streamMetrics.maxBatchSize, batch.length);
                streamMetrics.fileCount = diffItems.length;
                streamMetrics.renderableFileCount = codeViewItems.length;
                recordStreamMetrics(streamMetrics);
                lastFlushAt = performance.now();
                if (firstRender) {
                  firstRender = false;
                  status.remove();
                }
                if (!hadCodeItems) {
                  updateActiveFile(codeViewItems[0]?.id ?? diffItems[0]?.id ?? "");
                }
                window.__cmuxDiffViewer.items = diffItems;
                window.__cmuxDiffViewer.codeViewItems = codeViewItems;
                window.__cmuxDiffViewer.streamMetrics = streamMetrics;
              }

              function finalizeCodeViewLayout() {
                if (!codeView) {
                  return;
                }
                codeView.syncContainerHeight?.();
                codeView.render(true);
              }

              function scheduleNavigationRefresh(treesModule, force, dirtyCount = 1) {
                navigationRefreshState.treesModule = treesModule;
                navigationRefreshState.dirtyCount += dirtyCount;
                if (force || navigationRefreshState.lastRefreshAt === 0) {
                  refreshNavigation(navigationRefreshState.treesModule);
                  return;
                }
                const elapsed = performance.now() - navigationRefreshState.lastRefreshAt;
                if (navigationRefreshState.dirtyCount >= 1000 || elapsed >= 1000) {
                  refreshNavigation(navigationRefreshState.treesModule);
                  return;
                }
                if (navigationRefreshState.timeout !== 0) {
                  return;
                }
                const delay = Math.max(0, 1000 - elapsed);
                navigationRefreshState.timeout = window.setTimeout(() => {
                  navigationRefreshState.timeout = 0;
                  refreshNavigation(navigationRefreshState.treesModule);
                }, delay);
              }

              function refreshNavigation(treesModule) {
                if (navigationRefreshState.timeout !== 0) {
                  window.clearTimeout(navigationRefreshState.timeout);
                  navigationRefreshState.timeout = 0;
                }
                navigationRefreshState.dirtyCount = 0;
                navigationRefreshState.lastRefreshAt = performance.now();
                streamMetrics.treeRefreshCount += 1;
                currentTreeSource = createFileTreeSourceFromModel(diffModel);
                refreshFileExplorerSource(currentTreeSource, treesModule);
                updateToolbarState();
                recordStreamMetrics(streamMetrics);
              }

              const response = await fetch(payload.patchURL, { cache: "no-store" });
              if (!response.ok) {
                throw new Error(`${label("loadingDiff")} (${response.status})`);
              }

              if (!response.body?.getReader) {
                const text = await response.text();
                await appendParsedPatchText(text, parsePatchFiles, enqueueFileDiff);
                await maybeFlushPendingItems(true);
                finalizeCodeViewLayout();
                scheduleNavigationRefresh(treesModule, true);
                streamMetrics.completedAt = performance.now();
                return;
              }

              const decoder = new TextDecoder();
              const reader = response.body.getReader();
              const gitMarker = "diff --git ";
              const gitMarkerWithNewline = "\\n" + gitMarker;
              const gitMarkerSearchTailLength = gitMarkerWithNewline.length - 1;
              const nonWhitespacePattern = /\\S/;

              function nextGitBoundaryIndex(text, start) {
                const offset = Math.max(start, 0);
                if (offset === 0 && text.startsWith(gitMarker)) {
                  return 0;
                }
                const index = text.indexOf(gitMarkerWithNewline, offset);
                return index === -1 ? undefined : index + 1;
              }

              function nextGitBoundarySearchStart(text, start) {
                return Math.max(start, text.length - gitMarkerSearchTailLength);
              }

              function commitMetadataBoundaryIndex(text, start, end) {
                const minimum = Math.max(start, 0);
                const maximum = Math.min(end, text.length);
                if (minimum >= maximum) {
                  return undefined;
                }
                let index = text.lastIndexOf("\\nFrom ", maximum - 1);
                while (index !== -1) {
                  const boundary = index + 1;
                  if (boundary < minimum) {
                    return undefined;
                  }
                  if (boundary >= maximum) {
                    index = text.lastIndexOf("\\nFrom ", index - 1);
                    continue;
                  }
                  const lineEnd = text.indexOf("\\n", boundary + 1);
                  const line = text.slice(boundary, lineEnd === -1 || lineEnd > maximum ? maximum : lineEnd);
                  if (commitMetadataPattern.test(line)) {
                    return boundary;
                  }
                  index = text.lastIndexOf("\\nFrom ", index - 1);
                }
                return undefined;
              }

              function commitMetadataFromFileText(fileText) {
                const firstGitBoundary = nextGitBoundaryIndex(fileText, 0);
                if (firstGitBoundary == null || firstGitBoundary <= 0) {
                  return undefined;
                }
                const metadata = fileText.slice(0, firstGitBoundary);
                return commitMetadataPattern.test(metadata) ? metadata : undefined;
              }

              async function appendCompleteFileText(fileText) {
                if (fileText.trim() === "") {
                  return;
                }
                const metadata = commitMetadataFromFileText(fileText);
                if (metadata != null) {
                  currentPatchPrefix = commitMetadataLabel(metadata, patchMetadataIndex);
                  patchMetadataIndex += 1;
                }
                const cacheKey = `cmux-diff-file-${diffModel.fileIndex}`;
                await enqueueFileDiff(processFile(fileText, {
                  cacheKey,
                  isGitDiff: true,
                }), currentPatchPrefix);
              }

              function createStreamingPatchFileSplitter() {
                let boundaryIndex;
                let buffer = "";
                let searchStart = 0;
                let sawGitBoundary = false;

                function takeAvailableFile() {
                  if (boundaryIndex == null) {
                    boundaryIndex = nextGitBoundaryIndex(buffer, searchStart);
                    if (boundaryIndex == null) {
                      searchStart = nextGitBoundarySearchStart(buffer, 0);
                      return null;
                    }
                    sawGitBoundary = true;
                    searchStart = boundaryIndex + 1;
                  }

                  while (true) {
                    const currentBoundary = boundaryIndex;
                    if (currentBoundary == null) {
                      return null;
                    }
                    const nextBoundary = nextGitBoundaryIndex(buffer, searchStart);
                    if (nextBoundary == null) {
                      searchStart = nextGitBoundarySearchStart(buffer, currentBoundary + 1);
                      return null;
                    }
                    const splitBoundary = commitMetadataBoundaryIndex(buffer, currentBoundary + 1, nextBoundary) ?? nextBoundary;
                    const fileText = buffer.slice(0, splitBoundary);
                    buffer = buffer.slice(splitBoundary);
                    boundaryIndex = nextGitBoundaryIndex(buffer, 0);
                    searchStart = boundaryIndex == null ? 0 : boundaryIndex + 1;
                    if (nonWhitespacePattern.test(fileText)) {
                      return fileText;
                    }
                  }
                }

                return {
                  push(text) {
                    if (text.length > 0) {
                      buffer += text;
                    }
                  },
                  takeAvailableFile,
                  finish() {
                    const fileText = takeAvailableFile();
                    if (fileText != null) {
                      return { fileText };
                    }
                    if (!nonWhitespacePattern.test(buffer)) {
                      buffer = "";
                      return {};
                    }
                    if (!sawGitBoundary) {
                      const fallbackPatchContent = buffer;
                      buffer = "";
                      return { fallbackPatchContent };
                    }
                    const trailingFileText = buffer;
                    buffer = "";
                    return { fileText: trailingFileText };
                  },
                };
              }

              async function drainPatchFileSplitter(splitter) {
                let fileText;
                while ((fileText = splitter.takeAvailableFile()) != null) {
                  await appendCompleteFileText(fileText);
                }
              }

              const splitter = createStreamingPatchFileSplitter();
              let currentPatchPrefix;
              let patchMetadataIndex = 0;
              while (true) {
                const { done, value } = await reader.read();
                if (done) {
                  const tail = decoder.decode();
                  if (tail.length > 0) {
                    splitter.push(tail);
                    await drainPatchFileSplitter(splitter);
                  }
                  break;
                }
                splitter.push(decoder.decode(value, { stream: true }));
                await drainPatchFileSplitter(splitter);
              }

              const finalFile = splitter.finish();
              if (finalFile.fileText != null) {
                await appendCompleteFileText(finalFile.fileText);
                await drainPatchFileSplitter(splitter);
              } else if (finalFile.fallbackPatchContent != null) {
                await appendParsedPatchText(finalFile.fallbackPatchContent, parsePatchFiles, enqueueFileDiff);
              }
              await maybeFlushPendingItems(true);
              finalizeCodeViewLayout();
              scheduleNavigationRefresh(treesModule, true);
              streamMetrics.completedAt = performance.now();
              recordStreamMetrics(streamMetrics);
            }

            function recordStreamMetrics(metrics) {
              document.body.dataset.streamFileCount = String(metrics.fileCount ?? diffItems.length);
              document.body.dataset.streamRenderableFileCount = String(metrics.renderableFileCount ?? codeViewItems.length);
              document.body.dataset.streamFlushCount = String(metrics.flushCount ?? 0);
              document.body.dataset.streamMaxBatchSize = String(metrics.maxBatchSize ?? 0);
              document.body.dataset.streamTreeRefreshCount = String(metrics.treeRefreshCount ?? 0);
              if (Number.isFinite(metrics.completedAt) && metrics.completedAt > 0) {
                document.body.dataset.streamElapsedMs = String(Math.round(metrics.completedAt - metrics.startedAt));
              }
            }

            async function appendParsedPatchText(patchText, parsePatchFiles, enqueueFileDiff) {
              const patches = parsePatchFiles(patchText, "cmux-diff");
              const hasMultiplePatches = patches.length > 1;
              for (const [patchIndex, patch] of patches.entries()) {
                const patchPrefix = hasMultiplePatches ? commitMetadataLabel(patch.patchMetadata, patchIndex) : undefined;
                for (const fileDiff of patch.files ?? []) {
                  await enqueueFileDiff(fileDiff, patchPrefix);
                }
              }
            }

            function createStreamingDiffModel() {
              return {
                diffStats: {
                  addedLines: 0,
                  deletedLines: 0,
                  fileCount: 0,
                  totalLinesOfCode: 0,
                },
                fileIndex: 0,
                gitStatusByPath: new Map(),
                itemIdToFile: new Map(),
                itemIdByTreePath: new Map(),
                lastTreeSource: undefined,
                nextCollisionSuffixByBase: new Map(),
                items: [],
                pathStateByTreePath: new Map(),
                paths: [],
                pathToItemId: new Map(),
                pendingGitStatusRemovePaths: new Set(),
                pendingGitStatusSetByPath: new Map(),
                pendingItems: [],
                pendingItemById: new Map(),
                pendingStatsChanged: false,
                statsByPath: new Map(),
                treePathByItemId: new Map(),
              };
            }

            function createFileTreeSourceFromModel(model) {
              const previousSource = model.lastTreeSource;
              const gitStatusPatch = buildGitStatusPatch(model);
              const source = {
                diffStats: { ...model.diffStats },
                gitStatus: Array.from(model.gitStatusByPath.values()),
                gitStatusPatch,
                pathCount: model.paths.length,
                paths: model.paths,
                pathToItemId: model.pathToItemId,
                previousSource,
                statsChanged: model.pendingStatsChanged,
                statsByPath: model.statsByPath,
                treePathByItemId: model.treePathByItemId,
              };
              model.pendingStatsChanged = false;
              model.lastTreeSource = source;
              return source;
            }

            function buildGitStatusPatch(model) {
              if (model.pendingGitStatusRemovePaths.size === 0 && model.pendingGitStatusSetByPath.size === 0) {
                return undefined;
              }
              const patch = {};
              if (model.pendingGitStatusRemovePaths.size > 0) {
                patch.remove = Array.from(model.pendingGitStatusRemovePaths);
                model.pendingGitStatusRemovePaths.clear();
              }
              if (model.pendingGitStatusSetByPath.size > 0) {
                patch.set = Array.from(model.pendingGitStatusSetByPath.values());
                model.pendingGitStatusSetByPath.clear();
              }
              return patch;
            }

            function yieldToNextFrame() {
              return new Promise((resolve) => {
                let resolved = false;
                let timeout = 0;
                const done = () => {
                  if (resolved) {
                    return;
                  }
                  resolved = true;
                  if (timeout !== 0) {
                    window.clearTimeout(timeout);
                  }
                  resolve();
                };
                if (document.visibilityState === "visible" && document.hasFocus()) {
                  timeout = window.setTimeout(done, 50);
                  window.requestAnimationFrame(done);
                } else if (typeof MessageChannel !== "undefined") {
                  const channel = new MessageChannel();
                  channel.port1.onmessage = done;
                  channel.port2.postMessage(undefined);
                } else {
                  queueMicrotask(done);
                }
              });
            }

            async function loadPatchText() {
              if (patchTextPromise.value == null) {
                patchTextPromise.value = fetch(payload.patchURL, { cache: "no-store" }).then(async (response) => {
                  if (!response.ok) {
                    throw new Error(`${label("loadingDiff")} (${response.status})`);
                  }
                  return response.text();
                });
              }
              return patchTextPromise.value;
            }

            function applyViewerAppearance(appearance) {
              const rootStyle = document.documentElement.style;
              rootStyle.setProperty("--cmux-diff-bg-light", appearance.themes.light.background);
              rootStyle.setProperty("--cmux-diff-bg-dark", appearance.themes.dark.background);
              rootStyle.setProperty("--cmux-diff-fg-light", appearance.themes.light.foreground);
              rootStyle.setProperty("--cmux-diff-fg-dark", appearance.themes.dark.foreground);
              rootStyle.setProperty("--cmux-diff-selection-bg-light", appearance.themes.light.selectionBackground);
              rootStyle.setProperty("--cmux-diff-selection-bg-dark", appearance.themes.dark.selectionBackground);
              rootStyle.setProperty("--cmux-diff-code-font-family", cssFontFamily(appearance.fontFamily));
              rootStyle.setProperty("--cmux-diff-font-size", `${appearance.fontSize}px`);
              rootStyle.setProperty("--cmux-diff-line-height", `${appearance.lineHeight}px`);
            }

            function cssFontFamily(fontFamily) {
              const family = typeof fontFamily === "string" && fontFamily.trim() !== "" ? fontFamily.trim() : "Menlo";
              return `${JSON.stringify(family)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
            }

            function setupToolbar() {
              filesToggle.innerHTML = icon("files");
              fileSearchToggle.innerHTML = icon("search");
              fileCollapseToggle.innerHTML = icon("sidebarCollapse");
              layoutToggle.innerHTML = icon(appState.layout);
              optionsButton.innerHTML = icon("dots");
              if (typeof payload.externalURL === "string" && payload.externalURL.length > 0) {
                externalLink.href = payload.externalURL;
                externalLink.innerHTML = icon("external");
                externalLink.hidden = false;
              }
              filesToggle.addEventListener("click", () => setFilesVisible(!appState.filesVisible));
              fileCollapseToggle.addEventListener("click", () => setFilesVisible(false));
              fileSearchToggle.addEventListener("click", () => setFileSearchOpen(!appState.fileSearchOpen));
              layoutToggle.addEventListener("click", () => setLayout(appState.layout === "split" ? "unified" : "split"));
              optionsButton.addEventListener("click", () => setOptionsMenuOpen(optionsMenu.hidden));
              document.addEventListener("click", (event) => {
                if (optionsMenu.hidden || toolbar.contains(event.target)) {
                  return;
                }
                setOptionsMenuOpen(false);
              });
              document.addEventListener("keydown", (event) => {
                if (event.key === "Escape") {
                  setOptionsMenuOpen(false);
                }
              });
              updateToolbarState();
            }

            function codeViewOptions() {
              return {
                layout: { paddingTop: 0, gap: 1, paddingBottom: 0 },
                diffStyle: appState.layout,
                diffIndicators: appState.diffIndicators,
                overflow: appState.wordWrap ? "wrap" : "scroll",
                expandUnchanged: appState.expandUnchanged,
                disableBackground: !appState.showBackgrounds,
                disableLineNumbers: !appState.lineNumbers,
                lineHoverHighlight: "number",
                enableLineSelection: true,
                enableGutterUtility: true,
                lineDiffType: appState.wordDiffs ? "word" : "none",
                stickyHeaders: true,
                unsafeCSS: codeViewUnsafeCSS(),
                theme: payload.appearance.theme,
                themeType: "system",
              };
            }

            function codeViewUnsafeCSS() {
              return `
                [data-diffs-header] {
                  container-type: scroll-state;
                  container-name: sticky-header;
                }
                @container sticky-header scroll-state(stuck: top) {
                  [data-diffs-header]::after {
                    position: absolute;
                    bottom: -1px;
                    left: 0;
                    width: 100%;
                    height: 1px;
                    content: '';
                    background-color: var(--cmux-diff-border);
                  }
                }
                [data-diffs-header=default],
                [data-diffs-header=default] [data-additions-count],
                [data-diffs-header=default] [data-deletions-count],
                [data-separator-wrapper],
                [data-separator-content],
                [data-unmodified-lines],
                [data-expand-button] {
                  font-family: var(--diffs-header-font-family, var(--diffs-header-font-fallback));
                }
              `;
            }

            function applyCodeViewOptions() {
              const options = codeViewOptions();
              if (!codeView) {
                syncWorkerRenderOptions();
                return;
              }
              codeView.setOptions(options);
              syncWorkerRenderOptions();
              codeView.render(true);
            }

            function syncWorkerRenderOptions() {
              if (!workerPool?.setRenderOptions) {
                return;
              }
              workerPool.setRenderOptions(workerHighlighterOptions())
                .then(() => codeView?.render(true))
                .catch((error) => console.warn("cmux diff worker render options update failed", error));
            }

            function setLayout(layout) {
              appState.layout = layout === "unified" ? "unified" : "split";
              updateToolbarState();
              applyCodeViewOptions();
            }

            function setFilesVisible(visible) {
              appState.filesVisible = visible;
              document.body.dataset.filesHidden = visible ? "false" : "true";
              filesSidebar.setAttribute("aria-hidden", String(!visible));
              if (visible) {
                filesSidebar.removeAttribute("inert");
              } else {
                filesSidebar.setAttribute("inert", "");
              }
              updateToolbarState();
            }

            function setFileSearchOpen(open) {
              appState.fileSearchOpen = Boolean(open);
              if (fileTree) {
                if (appState.fileSearchOpen) {
                  fileTree.openSearch("");
                } else {
                  fileTree.closeSearch();
                }
              }
              updateToolbarState();
            }

            function setCollapsed(collapsed) {
              appState.collapsed = collapsed;
              const nextCodeViewItems = codeViewItems.map((item) => ({
                ...item,
                collapsed,
                version: (item.version ?? 0) + 1,
              }));
              const codeItemsById = new Map(nextCodeViewItems.map((item) => [item.id, item]));
              const nextDiffItems = diffItems.map((item) => codeItemsById.get(item.id) ?? {
                ...item,
                collapsed,
                version: (item.version ?? 0) + 1,
              });
              codeViewItems.splice(0, codeViewItems.length, ...nextCodeViewItems);
              diffItems.splice(0, diffItems.length, ...nextDiffItems);
              if (codeView) {
                codeView.setItems(codeViewItems);
                codeView.render(true);
              }
              updateToolbarState();
            }

            function updateToolbarState() {
              filesToggle.setAttribute("aria-pressed", String(appState.filesVisible));
              filesToggle.title = appState.filesVisible ? label("hideFiles") : label("showFiles");
              filesToggle.setAttribute("aria-label", filesToggle.title);
              fileCollapseToggle.title = label("hideFiles");
              fileCollapseToggle.setAttribute("aria-label", fileCollapseToggle.title);
              layoutToggle.innerHTML = icon(appState.layout);
              layoutToggle.title = appState.layout === "split" ? label("switchToUnifiedDiff") : label("switchToSplitDiff");
              layoutToggle.setAttribute("aria-label", layoutToggle.title);
              optionsButton.setAttribute("aria-expanded", String(!optionsMenu.hidden));
              document.documentElement.dataset.layout = appState.layout;
              document.documentElement.dataset.wordWrap = String(appState.wordWrap);
              document.documentElement.dataset.diffIndicators = appState.diffIndicators;
              fileSearchToggle.disabled = !fileTree;
              fileSearchToggle.setAttribute("aria-pressed", String(appState.fileSearchOpen));
              fileSearchToggle.title = appState.fileSearchOpen ? label("hideFileSearch") : label("showFileSearch");
              fileSearchToggle.setAttribute("aria-label", fileSearchToggle.title);
            }

            function setOptionsMenuOpen(open) {
              if (open) {
                renderOptionsMenu();
              }
              optionsMenu.hidden = !open;
              updateToolbarState();
            }

            function renderOptionsMenu() {
              optionsMenu.textContent = "";
              const items = [
                { label: label("refresh"), icon: "refresh", action: () => window.location.reload() },
                { label: appState.wordWrap ? label("disableWordWrap") : label("enableWordWrap"), icon: "wrap", checked: appState.wordWrap, action: () => {
                  appState.wordWrap = !appState.wordWrap;
                  applyCodeViewOptions();
                } },
                { label: appState.collapsed ? label("expandAllDiffs") : label("collapseAllDiffs"), icon: "collapse", checked: appState.collapsed, action: () => setCollapsed(!appState.collapsed) },
                "separator",
                { label: appState.filesVisible ? label("hideFiles") : label("showFiles"), icon: "files", checked: appState.filesVisible, action: () => setFilesVisible(!appState.filesVisible) },
                { label: appState.expandUnchanged ? label("collapseUnchangedContext") : label("expandUnchangedContext"), icon: "document", checked: appState.expandUnchanged, action: () => {
                  appState.expandUnchanged = !appState.expandUnchanged;
                  applyCodeViewOptions();
                } },
                { label: appState.showBackgrounds ? label("hideBackgrounds") : label("showBackgrounds"), icon: "background", checked: appState.showBackgrounds, action: () => {
                  appState.showBackgrounds = !appState.showBackgrounds;
                  applyCodeViewOptions();
                } },
                { label: appState.lineNumbers ? label("hideLineNumbers") : label("showLineNumbers"), icon: "numbers", checked: appState.lineNumbers, action: () => {
                  appState.lineNumbers = !appState.lineNumbers;
                  applyCodeViewOptions();
                } },
                { label: appState.wordDiffs ? label("disableWordDiffs") : label("enableWordDiffs"), icon: "word", checked: appState.wordDiffs, action: () => {
                  appState.wordDiffs = !appState.wordDiffs;
                  applyCodeViewOptions();
                } },
                { kind: "segment", label: label("indicatorStyle"), icon: "bars", options: [
                  { value: "bars", icon: "bars", label: label("bars") },
                  { value: "classic", icon: "classic", label: label("classic") },
                  { value: "none", icon: "eye", label: label("none") },
                ] },
                "separator",
                { label: label("copyGitApplyCommand"), icon: "clipboard", action: copyGitApplyCommand },
              ];
              for (const item of items) {
                if (item === "separator") {
                  const separator = document.createElement("div");
                  separator.className = "menu-separator";
                  optionsMenu.append(separator);
                  continue;
                }
                if (item.kind === "segment") {
                  const row = document.createElement("div");
                  row.className = "menu-item menu-segment";
                  row.setAttribute("role", "presentation");
                  row.innerHTML = `${icon(item.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`;
                  row.querySelector(".menu-label").textContent = item.label;
                  const controls = row.querySelector(".menu-segment-controls");
                  for (const option of item.options) {
                    const button = document.createElement("button");
                    button.type = "button";
                    button.className = "segment-button";
                    button.title = option.label;
                    button.setAttribute("aria-label", option.label);
                    button.setAttribute("aria-pressed", String(appState.diffIndicators === option.value));
                    button.innerHTML = icon(option.icon);
                    button.addEventListener("click", () => {
                      appState.diffIndicators = option.value;
                      applyCodeViewOptions();
                      renderOptionsMenu();
                      updateToolbarState();
                    });
                    controls.append(button);
                  }
                  optionsMenu.append(row);
                  continue;
                }
                const button = document.createElement("button");
                button.type = "button";
                button.className = "menu-item";
                button.setAttribute("role", item.checked == null ? "menuitem" : "menuitemcheckbox");
                if (item.checked != null) {
                  button.setAttribute("aria-checked", String(Boolean(item.checked)));
                }
                button.disabled = Boolean(item.disabled);
                button.innerHTML = `${icon(item.icon)}<span class="menu-label"></span><span class="menu-check">${item.checked ? icon("check") : ""}</span>`;
                button.querySelector(".menu-label").textContent = item.label;
                button.addEventListener("click", () => {
                  if (button.disabled) {
                    return;
                  }
                  item.action?.();
                  renderOptionsMenu();
                  updateToolbarState();
                });
                optionsMenu.append(button);
              }
            }

            function safeGitApplyDelimiter(patch) {
              const lines = new Set(patch.split(/\\r?\\n/));
              let delimiter = "CMUX_DIFF_PATCH";
              let index = 0;
              while (lines.has(delimiter)) {
                index += 1;
                delimiter = `CMUX_DIFF_PATCH_${index}`;
              }
              return delimiter;
            }

            async function copyGitApplyCommand() {
              const newline = String.fromCharCode(10);
              const patchText = await loadPatchText();
              const patch = patchText.endsWith(newline) ? patchText : `${patchText}${newline}`;
              const delimiter = safeGitApplyDelimiter(patch);
              const command = `git apply <<'${delimiter}'${newline}${patch}${delimiter}`;
              if (navigator.clipboard?.writeText) {
                try {
                  await navigator.clipboard.writeText(command);
                } catch {
                  fallbackCopyText(command);
                }
              } else {
                fallbackCopyText(command);
              }
              optionsButton.title = label("copiedGitApplyCommand");
              optionsButton.setAttribute("aria-label", label("copiedGitApplyCommand"));
            }

            function fallbackCopyText(text) {
              const textarea = document.createElement("textarea");
              textarea.value = text;
              textarea.setAttribute("readonly", "");
              textarea.style.position = "fixed";
              textarea.style.left = "-9999px";
              document.body.append(textarea);
              textarea.select();
              document.execCommand("copy");
              textarea.remove();
            }

            function setupSourceSelector(options) {
              sourceDetail.textContent = diffSourceDetail();
              if (!Array.isArray(options) || options.length < 2) {
                return;
              }
              sourceSelect.textContent = "";
              const selected = options.find((option) => option.selected) ?? options.find((option) => !option.disabled);
              for (const option of options) {
                const item = document.createElement("option");
                item.value = option.value;
                item.textContent = option.label;
                item.disabled = option.disabled || !option.url;
                item.selected = option.value === selected?.value;
                if (option.message) {
                  item.title = option.message;
                }
                sourceSelect.append(item);
              }
              sourceDetail.textContent = selected?.sourceLabel ?? diffSourceDetail();
              sourceSelect.hidden = false;
              sourceSelect.addEventListener("change", () => {
                const next = options.find((option) => option.value === sourceSelect.value);
                if (!next?.url) {
                  sourceSelect.value = selected?.value ?? "";
                  return;
                }
                status.dataset.error = "false";
                status.textContent = label("loadingDiff");
                window.location.href = next.url;
              });
            }

            function diffSourceDetail() {
              const parts = [payload.sourceLabel, payload.repoRoot, payload.branchBaseRef]
                .filter((value) => typeof value === "string" && value.trim() !== "");
              return parts.join(" | ");
            }

            function setupNavigationSelector(selectElement, options, fallbackValue, labelText) {
              if (!selectElement || !Array.isArray(options) || options.length < 2) {
                return;
              }
              selectElement.textContent = "";
              const selected = options.find((option) => option.selected) ?? options.find((option) => !option.disabled);
              for (const option of options) {
                const item = document.createElement("option");
                item.value = option.value;
                item.textContent = option.label;
                item.disabled = option.disabled || !option.url;
                item.selected = option.value === selected?.value;
                if (option.message) {
                  item.title = option.message;
                }
                selectElement.append(item);
              }
              selectElement.hidden = false;
              selectElement.title = labelText;
              selectElement.addEventListener("change", () => {
                const next = options.find((option) => option.value === selectElement.value);
                if (!next?.url) {
                  selectElement.value = selected?.value ?? fallbackValue ?? "";
                  return;
                }
                status.dataset.error = "false";
                status.textContent = label("loadingDiff");
                window.location.href = next.url;
              });
            }

            function setupFileExplorer(items, treesModule) {
              setupFileExplorerSource(createFileTreeSource(items), treesModule);
            }

            function setupFileExplorerSource(source, treesModule) {
              const itemCount = sourcePathCount(source);
              const canUsePierreTree = canUsePierreFileTree(treesModule);
              syncFileTreeSelectionMaps(source, []);
              if (fileTree) {
                fileTree.cleanUp?.();
                fileTree = null;
              }
              fileTreeSource = null;
              appState.fileSearchOpen = false;
              fileList.textContent = "";
              filesCount.textContent = `${itemCount}`;
              updateDiffStatsFromSource(source);
              if (canUsePierreTree) {
                try {
                  setupPierreFileTree(source, treesModule);
                  updateToolbarState();
                  return;
                } catch (error) {
                  console.warn("cmux diff file tree setup failed", error);
                }
              }
              const entries = sourceEntries(source);
              syncFileTreeSelectionMaps(source, entries);
              setupFlatFileExplorer(entries);
              updateToolbarState();
            }

            function refreshFileExplorer(items, treesModule) {
              refreshFileExplorerSource(createFileTreeSource(items), treesModule);
            }

            function refreshFileExplorerSource(source, treesModule) {
              const itemCount = sourcePathCount(source);
              syncFileTreeSelectionMaps(source, []);
              filesCount.textContent = `${itemCount}`;
              updateDiffStatsFromSource(source);
              if (fileTree && fileList.dataset.treeMode === "pierre" && treesModule?.preparePresortedFileTreeInput) {
                refreshPierreFileTree(source, treesModule);
                return;
              }
              if (fileTree || fileList.childElementCount === 0) {
                setupFileExplorerSource(source, treesModule);
                return;
              }
              const entries = sourceEntries(source);
              syncFileTreeSelectionMaps(source, entries);
              fileList.textContent = "";
              setupFlatFileExplorer(entries);
            }

            function setupPierreFileTree(source, treesModule) {
              const { FileTree, preparePresortedFileTreeInput } = treesModule;
              const paths = sourcePaths(source);
              fileTreeSource = source;
              const initialSelectedPath = paths[0];
              useFileTreeStatsFromSource(source);
              fileList.dataset.treeMode = "pierre";
              fileTree = new FileTree({
                flattenEmptyDirectories: true,
                id: "cmux-diff-file-tree",
                initialExpansion: "open",
                initialSelectedPaths: initialSelectedPath ? [initialSelectedPath] : [],
                initialVisibleRowCount: getInitialFileTreeRowCount(),
                itemHeight: 24,
                overscan: 12,
                preparedInput: preparePresortedFileTreeInput(paths),
                presorted: true,
                search: true,
                searchBlurBehavior: "retain",
                stickyFolders: true,
                gitStatus: source.gitStatus,
                renderRowDecoration(context) {
                  if (context.item.kind !== "file") {
                    return null;
                  }
                  const stats = fileTreeStatsByPath.get(context.item.path);
                  if (stats == null || (stats.added === 0 && stats.deleted === 0)) {
                    return null;
                  }
                  return {
                    text: `+${stats.added} -${stats.deleted}`,
                    title: `${stats.added} ${label("additions")}, ${stats.deleted} ${label("deletions")}`,
                  };
                },
                sort: () => 0,
                unsafeCSS: fileTreeUnsafeCSS(),
                onSelectionChange(paths) {
                  if (suppressTreeSelectionChange) {
                    return;
                  }
                  const selectedPath = paths[paths.length - 1];
                  const itemId = itemIdByTreePath.get(selectedPath);
                  if (itemId) {
                    scrollToItem(itemId);
                  }
                },
              });
              fileTree.render({ containerWrapper: fileList });
            }

            function refreshPierreFileTree(source, treesModule) {
              const previousSource = fileTreeSource;
              const paths = sourcePaths(source);
              fileTreeSource = source;
              useFileTreeStatsFromSource(source);
              let resetTree = false;
              if (previousSource && (source.previousSource === previousSource || isPathPrefix(previousSource, source)) && source.pathCount >= previousSource.pathCount) {
                const addedPaths = source.paths.slice(previousSource.pathCount, source.pathCount);
                if (addedPaths.length > 0) {
                  try {
                    fileTree.batch(addedPaths.map((path) => ({ type: "add", path })));
                  } catch (error) {
                    console.warn("cmux diff file tree incremental update failed; resetting paths", error);
                    fileTree.resetPaths(paths, {
                      preparedInput: treesModule.preparePresortedFileTreeInput(paths),
                    });
                    resetTree = true;
                  }
                }
              } else {
                fileTree.resetPaths(paths, {
                  preparedInput: treesModule.preparePresortedFileTreeInput(paths),
                });
                resetTree = true;
              }
              if (source.gitStatusPatch) {
                if (typeof fileTree.applyGitStatusPatch === "function") {
                  fileTree.applyGitStatusPatch(source.gitStatusPatch);
                } else {
                  fileTree.setGitStatus(source.gitStatus);
                }
              } else if (resetTree || source.statsChanged === true) {
                fileTree.setGitStatus(source.gitStatus);
              }
            }

            function createFileTreeSource(items) {
              const entries = buildTreeEntries(items);
              const paths = entries.map((entry) => entry.path);
              const pathToItemId = new Map(entries.map((entry) => [entry.path, entry.item.id]));
              const statsByPath = new Map(entries.map((entry) => [entry.path, entry.stats]));
              const treePathByItemId = new Map(entries.map((entry) => [entry.item.id, entry.path]));
              return {
                entries,
                gitStatus: entries
                  .filter((entry) => entry.status !== "modified")
                  .map((entry) => ({ path: entry.path, status: entry.status })),
                pathCount: paths.length,
                paths,
                pathToItemId,
                statsByPath,
                treePathByItemId,
              };
            }

            function canUsePierreFileTree(treesModule) {
              return Boolean(treesModule?.FileTree && treesModule?.preparePresortedFileTreeInput);
            }

            function sourcePathCount(source) {
              return source?.pathCount ?? source?.entries?.length ?? 0;
            }

            function sourceEntries(source) {
              const count = source?.pathCount ?? source?.entries?.length ?? 0;
              const entries = source?.entries ?? [];
              if (entries.length > 0) {
                return entries.length === count ? entries : entries.slice(0, count);
              }
              const paths = sourcePaths(source);
              const pathToItemId = source?.pathToItemId;
              const statsByPath = source?.statsByPath;
              return paths.map((path) => {
                const itemId = pathToItemId instanceof Map ? pathToItemId.get(path) : undefined;
                const item = itemId ? diffItemById.get(itemId) : undefined;
                const fileDiff = item?.fileDiff ?? {};
                return {
                  item: item ?? { id: itemId ?? path, fileDiff },
                  path,
                  status: gitStatus(fileDiff),
                  stats: statsByPath instanceof Map ? statsByPath.get(path) ?? fileStats(fileDiff) : fileStats(fileDiff),
                };
              });
            }

            function sourcePaths(source) {
              const count = source?.pathCount ?? source?.paths?.length ?? 0;
              const paths = source?.paths ?? [];
              return paths.length === count ? paths : paths.slice(0, count);
            }

            function isPathPrefix(previousSource, nextSource) {
              const previousPaths = previousSource?.paths;
              const nextPaths = nextSource?.paths;
              const previousCount = previousSource?.pathCount ?? previousPaths?.length ?? 0;
              const nextCount = nextSource?.pathCount ?? nextPaths?.length ?? 0;
              if (!Array.isArray(previousPaths) || !Array.isArray(nextPaths) || previousCount > nextCount) {
                return false;
              }
              for (let index = 0; index < previousCount; index += 1) {
                if (previousPaths[index] !== nextPaths[index]) {
                  return false;
                }
              }
              return true;
            }

            function useFileTreeStatsFromSource(source) {
              if (source?.statsByPath instanceof Map) {
                fileTreeStatsByPath = source.statsByPath;
                return;
              }
              fileTreeStatsByPath = new Map();
              const treeEntries = sourceEntries(source);
              for (const entry of treeEntries) {
                fileTreeStatsByPath.set(entry.path, entry.stats);
              }
            }

            function syncFileTreeSelectionMaps(source, entries) {
              if (source?.pathToItemId instanceof Map && source?.treePathByItemId instanceof Map) {
                itemIdByTreePath = source.pathToItemId;
                treePathByItemId = source.treePathByItemId;
              } else if (source?.pathToItemId instanceof Map) {
                itemIdByTreePath = source.pathToItemId;
                treePathByItemId = new Map();
                for (const [path, itemId] of itemIdByTreePath) {
                  treePathByItemId.set(itemId, path);
                }
              } else {
                itemIdByTreePath = new Map();
                treePathByItemId = new Map();
                for (const entry of entries) {
                  const itemId = entry.item?.id;
                  if (!itemId) {
                    continue;
                  }
                  itemIdByTreePath.set(entry.path, itemId);
                  treePathByItemId.set(itemId, entry.path);
                }
              }
              if (activeTreePath && !itemIdByTreePath.has(activeTreePath)) {
                activeTreePath = "";
              }
            }

            function setupFlatFileExplorer(entries) {
              delete fileList.dataset.treeMode;
              for (const entry of entries) {
                const item = entry.item;
                const fileDiff = item.fileDiff ?? {};
                const stats = entry.stats ?? fileStats(fileDiff);
                const button = document.createElement("button");
                button.type = "button";
                button.className = "file-entry";
                button.dataset.itemId = item.id;
                button.title = fileName(fileDiff);
                button.innerHTML = `
                  <span class="file-status">${fileStatus(fileDiff)}</span>
                  <span class="file-name"></span>
                  <span class="file-stats">
                    <span class="stat-add">+${stats.added}</span>
                    <span class="stat-del">-${stats.deleted}</span>
                  </span>
                `;
                button.querySelector(".file-name").textContent = fileName(fileDiff);
                button.addEventListener("click", () => scrollToItem(item.id));
                fileList.append(button);
              }
            }

            function resetTreePathMaps() {
              activeTreePath = "";
              itemIdByTreePath = new Map();
              treePathByItemId = new Map();
            }

            function buildTreeEntries(items) {
              resetTreePathMaps();
              const pathCounts = new Map();
              const pathOrdinals = new Map();
              for (const item of items) {
                const name = fileName(item.fileDiff ?? {});
                pathCounts.set(name, (pathCounts.get(name) ?? 0) + 1);
              }
              return items.map((item) => {
                const fileDiff = item.fileDiff ?? {};
                const basePath = fileName(fileDiff);
                const nextOrdinal = (pathOrdinals.get(basePath) ?? 0) + 1;
                pathOrdinals.set(basePath, nextOrdinal);
                const treePath = pathCounts.get(basePath) > 1 ? `${basePath} (${nextOrdinal})` : basePath;
                const stats = fileStats(fileDiff);
                treePathByItemId.set(item.id, treePath);
                itemIdByTreePath.set(treePath, item.id);
                return {
                  item,
                  path: treePath,
                  status: gitStatus(fileDiff),
                  stats,
                };
              });
            }

            function getInitialFileTreeRowCount() {
              const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
              if (!Number.isFinite(viewportHeight) || viewportHeight <= 0) {
                return 25;
              }
              return Math.min(96, Math.max(25, Math.ceil(viewportHeight / 24)));
            }

            function fileTreeUnsafeCSS() {
              return `
                [data-file-tree-search-container][data-open='false'] {
                  display: none;
                }
                [data-file-tree-search-container] {
                  margin: 0 4px 8px 0;
                  padding: 0 5px 8px 1px;
                  border-bottom: 1px solid var(--trees-border-color);
                }
                [data-file-tree-virtualized-scroll='true'] {
                  padding-inline-start: 0;
                  padding-inline-end: 2px;
                  margin-inline-end: 2px;
                }
                [data-item-contains-git-change='true'] > [data-item-section='git'] {
                  display: none;
                }
                [data-item-type='folder'] {
                  color: color-mix(in lab, var(--trees-fg) 85%, var(--trees-bg));
                  font-weight: 500;
                }
                [data-file-tree-sticky-overlay-content] {
                  box-shadow: 0 1px 0 var(--trees-border-color);
                }
              `;
            }

            function updateDiffStats(items) {
              updateDiffStatsFromEntries(items.map((item) => ({
                item,
                stats: fileStats(item.fileDiff ?? {}),
              })));
            }

            function updateDiffStatsFromSource(source) {
              const stats = source?.diffStats;
              if (stats && Number.isFinite(stats.addedLines) && Number.isFinite(stats.deletedLines) && Number.isFinite(stats.fileCount)) {
                statsFiles.textContent = `${stats.fileCount}`;
                statsAdded.textContent = `+${stats.addedLines}`;
                statsDeleted.textContent = `-${stats.deletedLines}`;
                return;
              }
              updateDiffStatsFromEntries(source?.entries ?? []);
            }

            function updateDiffStatsFromEntries(entries) {
              const totals = entries.reduce((sum, entry) => {
                const stats = entry.stats ?? fileStats(entry.item?.fileDiff ?? {});
                sum.added += stats.added;
                sum.deleted += stats.deleted;
                return sum;
              }, { added: 0, deleted: 0 });
              statsFiles.textContent = `${entries.length}`;
              statsAdded.textContent = `+${totals.added}`;
              statsDeleted.textContent = `-${totals.deleted}`;
            }

            function updateDiffStatsFromModel(model) {
              filesCount.textContent = `${model.diffStats.fileCount}`;
              statsFiles.textContent = `${model.diffStats.fileCount}`;
              statsAdded.textContent = `+${model.diffStats.addedLines}`;
              statsDeleted.textContent = `-${model.diffStats.deletedLines}`;
            }

            function setupJumpSelector(items) {
              jumpSelect.textContent = "";
              const placeholder = document.createElement("option");
              placeholder.value = "";
              placeholder.textContent = label("jumpToFile");
              jumpSelect.append(placeholder);
              jumpSelect.dataset.initialized = "true";
              for (const item of items) {
                const option = document.createElement("option");
                option.value = item.id;
                option.textContent = fileName(item.fileDiff ?? {});
                jumpSelect.append(option);
              }
              jumpSelect.hidden = items.length === 0;
              jumpSelect.onchange = () => {
                if (jumpSelect.value) {
                  scrollToItem(jumpSelect.value);
                }
              };
            }

            function appendJumpOptions(items) {
              if (items.length === 0) {
                return;
              }
              if (jumpSelect.dataset.initialized !== "true") {
                setupJumpSelector([]);
              }
              const fragment = document.createDocumentFragment();
              for (const item of items) {
                const option = document.createElement("option");
                option.value = item.id;
                option.textContent = fileName(item.fileDiff ?? {});
                fragment.append(option);
              }
              jumpSelect.append(fragment);
              jumpSelect.hidden = false;
            }

            function renameJumpOption(oldId, newId) {
              if (jumpSelect.dataset.initialized !== "true") {
                return;
              }
              for (const option of jumpSelect.options) {
                if (option.value === oldId) {
                  option.value = newId;
                  return;
                }
              }
            }

            function scrollToItem(itemId) {
              if (!codeView) {
                return;
              }
              const targetItemId = codeViewScrollTargetForItem(itemId);
              if (!targetItemId) {
                return;
              }
              codeView.scrollTo({ type: "item", id: targetItemId, align: "start", behavior: "smooth-auto" });
              updateActiveFile(targetItemId);
            }

            function codeViewScrollTargetForItem(itemId) {
              if (codeViewItemIds.has(itemId)) {
                return itemId;
              }
              const index = diffItems.findIndex((item) => item.id === itemId);
              if (index === -1) {
                return codeViewItems[0]?.id ?? "";
              }
              for (let next = index + 1; next < diffItems.length; next += 1) {
                if (codeViewItemIds.has(diffItems[next].id)) {
                  return diffItems[next].id;
                }
              }
              for (let previous = index - 1; previous >= 0; previous -= 1) {
                if (codeViewItemIds.has(diffItems[previous].id)) {
                  return diffItems[previous].id;
                }
              }
              return "";
            }

            function updateActiveFile(itemId) {
              if (!itemId || activeFileId === itemId) {
                return;
              }
              activeFileId = itemId;
              syncFileTreeSelection(itemId);
              for (const entry of fileList.querySelectorAll(".file-entry")) {
                entry.setAttribute("aria-current", entry.dataset.itemId === itemId ? "true" : "false");
              }
              if (jumpSelect.value !== itemId) {
                jumpSelect.value = itemId;
              }
            }

            function syncFileTreeSelection(itemId) {
              if (!fileTree) {
                return;
              }
              const nextPath = treePathByItemId.get(itemId);
              if (!nextPath || nextPath === activeTreePath) {
                return;
              }
              suppressTreeSelectionChange = true;
              try {
                if (activeTreePath) {
                  fileTree.getItem(activeTreePath)?.deselect();
                }
                fileTree.getItem(nextPath)?.select();
                fileTree.scrollToPath(nextPath, { focus: false, offset: "nearest" });
                activeTreePath = nextPath;
              } finally {
                scheduleRender(() => {
                  suppressTreeSelectionChange = false;
                });
              }
            }

            function fileName(fileDiff) {
              return fileDiff.name ?? fileDiff.newName ?? fileDiff.oldName ?? fileDiff.prevName ?? label("untitled");
            }

            function fileStatus(fileDiff) {
              switch (fileDiff.type) {
              case "new":
                return "A";
              case "deleted":
                return "D";
              case "rename-pure":
              case "rename-changed":
                return "R";
              default:
                return "M";
              }
            }

            function gitStatus(fileDiff) {
              return gitStatusType(fileDiff.type);
            }

            function gitStatusType(changeType) {
              switch (changeType) {
              case "new":
                return "added";
              case "deleted":
                return "deleted";
              case "rename-pure":
              case "rename-changed":
                return "renamed";
              default:
                return "modified";
              }
            }

            function fileStats(fileDiff) {
              const stats = { added: 0, deleted: 0 };
              for (const hunk of fileDiff.hunks ?? []) {
                stats.added += hunk.additionLines ?? 0;
                stats.deleted += hunk.deletionLines ?? 0;
              }
              return stats;
            }

            function sameFileStats(previousStats, stats) {
              return previousStats?.added === stats.added && previousStats?.deleted === stats.deleted;
            }

            function icon(name) {
              const paths = {
                background: '<rect x="4" y="4" width="12" height="12" rx="2"/><path d="M7 8h6"/><path d="M7 12h6"/>',
                bars: '<path d="M5 4v12"/><path d="M9 6v8"/><path d="M13 8v4"/>',
                check: '<path d="M4 10.5 8 14l8-9"/>',
                classic: '<path d="M4 5h12"/><path d="M4 10h12"/><path d="M4 15h12"/><path d="M7 3v4"/><path d="M13 8v4"/>',
                collapse: '<path d="M7 3v4H3"/><path d="M3 7l5-5"/><path d="M13 17v-4h4"/><path d="M17 13l-5 5"/>',
                document: '<path d="M6 3h6l4 4v10H6z"/><path d="M12 3v5h5"/>',
                dots: '<path d="M5 10h.01"/><path d="M10 10h.01"/><path d="M15 10h.01"/>',
                external: '<path d="M7 5H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-2"/><path d="M11 3h6v6"/><path d="m10 10 7-7"/>',
                eye: '<path d="M2.5 10s2.75-5 7.5-5 7.5 5 7.5 5-2.75 5-7.5 5-7.5-5-7.5-5z"/><circle cx="10" cy="10" r="2.4"/>',
                files: '<path d="M3 5h5l1.5 2H17v9.5H3z"/><path d="M3 7h14"/>',
                image: '<rect x="3" y="4" width="14" height="12" rx="2"/><circle cx="8" cy="8" r="1.3"/><path d="m4 15 4.5-4 3 2.8 2-1.8L17 15"/>',
                numbers: '<path d="M5 5h2v10"/><path d="M4 15h4"/><path d="M11 6.5a2 2 0 1 1 3.2 1.6L11 12h4"/><path d="M11 15h4"/>',
                refresh: '<path d="M16 8a6 6 0 0 0-10.3-3.7L4 6"/><path d="M4 3v3h3"/><path d="M4 12a6 6 0 0 0 10.3 3.7L16 14"/><path d="M16 17v-3h-3"/>',
                search: '<circle cx="8.5" cy="8.5" r="4.5"/><path d="m12 12 4 4"/>',
                sidebarCollapse: '<rect x="3.5" y="4" width="13" height="12" rx="2"/><path d="M12 4v12"/><path d="m8 8-2 2 2 2"/>',
                split: '<rect x="3" y="4" width="14" height="12" rx="2"/><path d="M10 4v12" data-accent="true"/><path d="M6 8h2"/><path d="M6 12h2"/><path d="M12 8h2"/><path d="M12 12h2"/>',
                unified: '<rect x="4" y="3.5" width="12" height="13" rx="2"/><path d="M7 7h6"/><path d="M7 10h6" data-accent="true"/><path d="M7 13h6"/>',
                word: '<path d="M3 6h14"/><path d="M3 10h8"/><path d="M3 14h11"/><path d="M14 10h3"/>',
                wrap: '<path d="M3 6h10a4 4 0 0 1 0 8H8"/><path d="m10 11-3 3 3 3"/>',
                clipboard: '<rect x="5" y="4" width="10" height="13" rx="2"/><path d="M8 4a2 2 0 0 1 4 0"/><path d="M8 7h4"/>',
              };
              return `<svg viewBox="0 0 20 20" aria-hidden="true">${paths[name] ?? ""}</svg>`;
            }

            function registerGhosttyTheme(registerCustomTheme, theme) {
              registerCustomTheme(theme.name, () => Promise.resolve(shikiThemeFromGhostty(theme)));
            }

            function preloadDiffHighlighter(appearance, items, getFiletypeFromFileName, preloadHighlighter) {
              const themes = Array.from(new Set([
                appearance.theme?.light,
                appearance.theme?.dark,
              ].filter(Boolean)));
              const langs = Array.from(new Set(items.map((item) => {
                const fileDiff = item.fileDiff ?? {};
                const name = fileDiff.name ?? fileDiff.newName ?? fileDiff.oldName ?? fileDiff.prevName ?? "";
                return fileDiff.lang ?? getFiletypeFromFileName(name) ?? "text";
              }).filter(Boolean)));
              return preloadHighlighter({
                themes,
                langs: langs.length > 0 ? langs : ["text"],
              });
            }

            function shikiThemeFromGhostty(theme) {
              const palette = theme.palette ?? {};
              const foreground = theme.foreground;
              const background = theme.background;
              return {
                name: theme.name,
                displayName: theme.ghosttyName,
                type: theme.type,
                colors: {
                  "editor.background": background,
                  "editor.foreground": foreground,
                  "terminal.background": background,
                  "terminal.foreground": foreground,
                  "terminal.ansiBlack": palette["0"] ?? foreground,
                  "terminal.ansiRed": palette["1"] ?? foreground,
                  "terminal.ansiGreen": palette["2"] ?? foreground,
                  "terminal.ansiYellow": palette["3"] ?? foreground,
                  "terminal.ansiBlue": palette["4"] ?? foreground,
                  "terminal.ansiMagenta": palette["5"] ?? foreground,
                  "terminal.ansiCyan": palette["6"] ?? foreground,
                  "terminal.ansiWhite": palette["7"] ?? foreground,
                  "terminal.ansiBrightBlack": palette["8"] ?? foreground,
                  "terminal.ansiBrightRed": palette["9"] ?? palette["1"] ?? foreground,
                  "terminal.ansiBrightGreen": palette["10"] ?? palette["2"] ?? foreground,
                  "terminal.ansiBrightYellow": palette["11"] ?? palette["3"] ?? foreground,
                  "terminal.ansiBrightBlue": palette["12"] ?? palette["4"] ?? foreground,
                  "terminal.ansiBrightMagenta": palette["13"] ?? palette["5"] ?? foreground,
                  "terminal.ansiBrightCyan": palette["14"] ?? palette["6"] ?? foreground,
                  "terminal.ansiBrightWhite": palette["15"] ?? foreground,
                  "gitDecoration.addedResourceForeground": palette["10"] ?? palette["2"] ?? "#32d74b",
                  "gitDecoration.deletedResourceForeground": palette["9"] ?? palette["1"] ?? "#ff453a",
                  "gitDecoration.modifiedResourceForeground": palette["12"] ?? palette["4"] ?? "#0a84ff",
                  "editor.selectionBackground": theme.selectionBackground,
                  "editor.selectionForeground": theme.selectionForeground,
                },
                tokenColors: [
                  { settings: { foreground, background } },
                  { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: palette["8"] ?? foreground, fontStyle: "italic" } },
                  { scope: ["string", "constant.other.symbol"], settings: { foreground: palette["2"] ?? foreground } },
                  { scope: ["constant.numeric", "constant.language", "support.constant"], settings: { foreground: palette["3"] ?? foreground } },
                  { scope: ["keyword", "storage", "storage.type"], settings: { foreground: palette["5"] ?? foreground } },
                  { scope: ["entity.name.function", "support.function"], settings: { foreground: palette["4"] ?? foreground } },
                  { scope: ["entity.name.type", "entity.name.class", "support.type"], settings: { foreground: palette["6"] ?? foreground } },
                  { scope: ["variable", "meta.definition.variable"], settings: { foreground } },
                  { scope: ["invalid", "message.error"], settings: { foreground: palette["9"] ?? palette["1"] ?? foreground } },
                ],
              };
            }

          </script>
        </body>
        </html>
        """
        try html.write(to: viewerURL, atomically: true, encoding: .utf8)
    }

    private func ensureDiffViewerAssets(nextTo viewerURL: URL) throws -> DiffViewerAssets {
        let sourceDirectory = try diffViewerBundledAssetDirectory()
        let assetDirectoryName = "pierre-diffs-1.2.1-trees-1.0.0-beta.4"
        let targetDirectory = viewerURL.deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(assetDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let assetPaths = try diffViewerBundledAssetRelativePaths(in: sourceDirectory)
        guard assetPaths.contains("diffs.mjs"),
              assetPaths.contains("trees.mjs"),
              assetPaths.contains("worker-pool/worker-pool.mjs"),
              assetPaths.contains("worker-pool/worker-portable.mjs") else {
            throw CLIError(message: "Bundled diff viewer entry assets not found")
        }
        for assetPath in assetPaths {
            try copyDiffViewerAsset(relativePath: assetPath, from: sourceDirectory, to: targetDirectory)
        }

        return DiffViewerAssets(
            diffsModuleURL: "./assets/\(assetDirectoryName)/diffs.mjs",
            treesModuleURL: "./assets/\(assetDirectoryName)/trees.mjs",
            workerPoolModuleURL: "./assets/\(assetDirectoryName)/worker-pool/worker-pool.mjs",
            workerModuleURL: "./assets/\(assetDirectoryName)/worker-pool/worker-portable.mjs",
            files: assetPaths.map { targetDirectory.appendingPathComponent($0, isDirectory: false) }
        )
    }

    private func copyDiffViewerAsset(relativePath: String, from sourceDirectory: URL, to targetDirectory: URL) throws {
        let fileManager = FileManager.default
        let sourceURL = sourceDirectory.appendingPathComponent(relativePath, isDirectory: false)
        let targetURL = targetDirectory.appendingPathComponent(relativePath, isDirectory: false)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CLIError(message: "Bundled diff viewer asset not found: \(relativePath)")
        }

        let sourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if isCurrentDiffViewerAsset(targetURL: targetURL, sourceValues: sourceValues) {
            return
        }

        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = targetURL.deletingLastPathComponent().appendingPathComponent(
            ".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            if rename(temporaryURL.path, targetURL.path) != 0 {
                let code = Int(errno)
                throw NSError(domain: NSPOSIXErrorDomain, code: code)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            if isCurrentDiffViewerAsset(targetURL: targetURL, sourceValues: sourceValues) {
                return
            }
            throw error
        }
    }

    private func diffViewerBundledAssetRelativePaths(in sourceDirectory: URL) throws -> [String] {
        let rootURL = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CLIError(message: "Failed to enumerate diff viewer assets")
        }

        var relativePaths: [String] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "mjs",
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            let standardized = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard standardized.path.hasPrefix(rootURL.path + "/") else {
                continue
            }
            relativePaths.append(String(standardized.path.dropFirst(rootURL.path.count + 1)))
        }
        return relativePaths.sorted()
    }

    private func isCurrentDiffViewerAsset(targetURL: URL, sourceValues: URLResourceValues) -> Bool {
        guard FileManager.default.fileExists(atPath: targetURL.path),
              let targetValues = try? targetURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              targetValues.fileSize == sourceValues.fileSize,
              let sourceDate = sourceValues.contentModificationDate,
              let targetDate = targetValues.contentModificationDate else {
            return false
        }
        return targetDate >= sourceDate
    }

    private func diffViewerBundledAssetDirectory() throws -> URL {
        let candidates = diffViewerBundledAssetDirectoryCandidates()
        if let directory = candidates.first {
            return directory
        }
        throw CLIError(message: "Bundled diff viewer assets not found")
    }

    private func diffViewerBundledAssetDirectoryCandidates() -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        var seen: Set<String> = []

        func appendIfExisting(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            let diffsAsset = standardized.appendingPathComponent("diffs.mjs", isDirectory: false)
            let treesAsset = standardized.appendingPathComponent("trees.mjs", isDirectory: false)
            guard fileManager.fileExists(atPath: diffsAsset.path),
                  fileManager.fileExists(atPath: treesAsset.path) else {
                return
            }
            candidates.append(standardized)
        }

        appendIfExisting(
            Bundle.main.resourceURL?
                .appendingPathComponent("markdown-viewer", isDirectory: true)
                .appendingPathComponent("diff-viewer", isDirectory: true)
        )

        if let executableURL = resolvedExecutableURL() {
            let execDir = executableURL.deletingLastPathComponent().standardizedFileURL
            for relativePath in [
                "markdown-viewer/diff-viewer",
                "../markdown-viewer/diff-viewer",
                "../../Resources/markdown-viewer/diff-viewer",
                "../../../Contents/Resources/markdown-viewer/diff-viewer"
            ] {
                appendIfExisting(execDir.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL)
            }

            var current = execDir
            for _ in 0..<6 {
                if current.pathExtension == "app" {
                    appendIfExisting(
                        current
                            .appendingPathComponent("Contents", isDirectory: true)
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("markdown-viewer", isDirectory: true)
                            .appendingPathComponent("diff-viewer", isDirectory: true)
                    )
                    break
                }
                let projectMarker = current.appendingPathComponent("cmux.xcodeproj/project.pbxproj", isDirectory: false)
                let repoAssetDirectory = current
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("markdown-viewer", isDirectory: true)
                    .appendingPathComponent("diff-viewer", isDirectory: true)
                if fileManager.fileExists(atPath: projectMarker.path) {
                    appendIfExisting(repoAssetDirectory)
                    break
                }
                current = current.deletingLastPathComponent().standardizedFileURL
            }
        }

        let devRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("diff-viewer", isDirectory: true)
        appendIfExisting(devRelative)
        return candidates
    }

    private func jsonScriptLiteral(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode diff viewer payload")
        }
        return text.replacingOccurrences(of: "</", with: "<\\/")
    }

    private func jsonStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode diff viewer string")
        }
        return text.replacingOccurrences(of: "</", with: "<\\/")
    }

    private func htmlEscaped(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func pruneDiffViewerFiles(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
            options: []
        ) else {
            return
        }

        let now = Date()
        let sorted = entries.compactMap { url -> (url: URL, date: Date)? in
            guard url.pathExtension == "html",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in sorted.enumerated() where index >= 50 && now.timeIntervalSince(entry.date) > 24 * 60 * 60 {
            try? FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: diffViewerPatchFileURL(for: entry.url))
        }

        for patchURL in entries where patchURL.pathExtension == "patch" {
            let htmlURL = patchURL.deletingPathExtension().appendingPathExtension("html")
            guard !FileManager.default.fileExists(atPath: htmlURL.path),
                  let values = try? patchURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  now.timeIntervalSince(values.contentModificationDate ?? values.creationDate ?? .distantPast) > 24 * 60 * 60 else {
                continue
            }
            try? FileManager.default.removeItem(at: patchURL)
        }

        for manifestURL in entries where manifestURL.lastPathComponent.hasPrefix(".manifest-") && manifestURL.pathExtension == "json" {
            guard let values = try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  now.timeIntervalSince(values.contentModificationDate ?? values.creationDate ?? .distantPast) > 24 * 60 * 60 else {
                continue
            }
            try? FileManager.default.removeItem(at: manifestURL)
        }
    }

    func openSubcommandUsage() -> String {
        """
        Usage: cmux open <path-or-url>... [options]

        Open files, directories, or URLs in cmux.
        Markdown files open in markdown preview tabs; other files open in file preview tabs.
        Multiple files open as tabs in the same target pane.

        Options:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Target surface whose pane should receive file tabs (default: $CMUX_SURFACE_ID)
          --pane <id|ref|index>        Target pane for file tabs
          --window <id|ref|index>      Target window
          --focus <true|false>         Focus opened file previews (default: true)
          --no-focus                   Do not focus opened file previews

        Examples:
          cmux open report.pdf
          cmux open image-a.png image-b.jpg
          cmux open ~/Downloads/movie.mov --pane pane:1
          cmux open https://example.com
        """
    }

    func diffSubcommandUsage() -> String {
        """
        Usage: cmux diff [patch-file|-] [options]

        Render a unified diff or patch in a cmux browser split.
        With no patch file or source, cmux diff reads piped stdin.

        Options:
          --source <name>              Diff source: unstaged, staged, branch, last-turn
          --unstaged                   Show unstaged git changes
          --staged                     Show staged git changes
          --branch                     Show current branch against merge base
          --last-turn                  Show changes since this surface's last agent-turn baseline
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Source surface to split from (default: $CMUX_SURFACE_ID)
          --window <id|ref|index>      Target window
          --cwd, --repo <path>          Git repository or worktree path for git sources
          --base <ref>                  Base ref for --branch (default: origin/HEAD or main)
          --focus <true|false>         Focus the diff browser split (default: false)
          --no-focus                   Do not focus the opened diff browser split
          --title <text>               Set the diff viewer title to the provided text
          --layout <split|unified>     Diff layout (default: split)
          --font-size <points>         Set diff font size (default: 10)

        Examples:
          cmux diff changes.patch
          git diff | cmux diff
          cmux diff --unstaged
          cmux diff --staged
          cmux diff --branch
          cmux diff --branch --base upstream/main --repo ../repo
          cmux diff --last-turn
          cmux diff pr.patch --layout unified --font-size 15 --focus true
        """
    }

    private func openCommandSummary(
        payloads: [[String: Any]],
        fileCount: Int,
        urlCount: Int,
        directoryCount: Int,
        idFormat: CLIIDFormat
    ) -> String {
        let filePayload = payloads.first { ($0["kind"] as? String) == "file" }?["payload"] as? [String: Any]
        let surfaceText = filePayload.flatMap { formatHandle($0, kind: "surface", idFormat: idFormat) }
        let paneText = filePayload.flatMap { formatHandle($0, kind: "pane", idFormat: idFormat) }
        var pieces = ["OK"]
        if fileCount > 0 {
            pieces.append("files=\(fileCount)")
            if let surfaceText { pieces.append("surface=\(surfaceText)") }
            if let paneText { pieces.append("pane=\(paneText)") }
        }
        if urlCount > 0 {
            pieces.append("urls=\(urlCount)")
        }
        if directoryCount > 0 {
            pieces.append("workspaces=\(directoryCount)")
        }
        return pieces.joined(separator: " ")
    }
}
