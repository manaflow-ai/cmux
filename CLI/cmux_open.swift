import CryptoKit
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
        static let repoOptions = 12
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
        case url(String, defaultFocus: Bool)
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
        var sessionId: String?
        var source: DiffSource?
        var inputs: [String] = []
    }

    struct DiffInput {
        var patch: String
        var localPatchURL: URL? = nil
        var sourceLabel: String
        var defaultTitle: String
        var emptyMessage: String?
        var externalURL: String?
        var remotePatchURL: URL? = nil
    }

    struct EmptyDiffSourceError: Error {
        var message: String
    }

    struct DiffSourceContext {
        var workspaceId: String?
        var surfaceId: String?
        var sessionId: String?
        var repoRoot: String?
        var branchBaseRef: String?
    }

    struct DiffViewerWriteResult {
        var fileURL: URL
        var url: URL
        var title: String
        var input: DiffInput
        var allowedFiles: [DiffViewerAllowedFile]
        var deferredSourceSet: DiffViewerDeferredSourceSet? = nil
        var completeDeferred: (() throws -> DiffViewerWriteResult)? = nil
    }

    struct DiffViewerDeferredSourceSet {
        var pages: [DiffViewerDeferredSourcePage]
        var layout: String
        var layoutSource: String
        var appearance: DiffViewerAppearance
        var runtime: URL?
        // Same-origin base for branchPicker URLs + group key for regeneration.
        var origin: URL?
        var groupID: String?
        // Session token bound to `origin`, threaded into the branchPicker
        // refs/regenerate URLs so the HTTP picker endpoints can authorize.
        var token: String?
    }

    struct DiffViewerDeferredSourcePage {
        var source: DiffSource
        var url: URL
        var viewerURL: URL
        var titleOverride: String?
        var context: DiffSourceContext
        var sourceOptions: [DiffViewerSourceOption]
        var repoOptions: [DiffViewerSourceOption]
        var baseOptions: [DiffViewerSourceOption]
        // Resolved smart-default base for this branch page (nil for non-branch
        // pages and non-current bases); rebuilt into the branchPicker payload at
        // write time so deferred completions reuse the same picker.
        var branchPickerBase: DiffBranchBase? = nil
        var allowsSourceFallback: Bool = false
        var sourceFallbacks: [DiffSource: DiffViewerDeferredSourceFallback] = [:]
    }

    struct DiffViewerDeferredSourceFallback {
        var url: URL
        var viewerURL: URL
        var context: DiffSourceContext
        var sourceOptions: [DiffViewerSourceOption]
        var repoOptions: [DiffViewerSourceOption]
        var baseOptions: [DiffViewerSourceOption]
    }

    private struct DiffViewerDeferredCompletion {
        var input: DiffInput
        var fileURL: URL
        var viewerURL: URL
        var completedPageURLs: Set<URL>
    }

    struct DiffViewerRepoOption {
        var repoRoot: String
        var label: String
    }

    private struct DiffViewerBranchBaseOption {
        var ref: String
        var label: String
    }

    struct DiffViewerGitHTMLSetTarget {
        var directory: URL
        var mapper: DiffViewerURLMapper
        var groupID: String
        var runtime: URL?
    }

    struct DiffViewerSourceOption {
        var value: String
        var label: String
        var selected: Bool
        var url: String?
        var disabled: Bool
        var message: String?
        var sourceLabel: String?
        var sessionSource: [String: Any]? = nil

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
            if let sessionSource { object["sessionSource"] = sessionSource }
            return object
        }
    }

    struct DiffViewerAssets {
        var appModuleURL: String
        var diffsModuleURL: String
        var treesModuleURL: String
        var workerPoolModuleURL: String
        var workerModuleURL: String
        var files: [URL]
    }

    struct DiffViewerSharedPayload {
        var labels: [String: Any]
        var shortcuts: [String: Any]
        var generatedAt: String
    }

    struct DiffViewerAllowedFile: Codable {
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

    struct DiffViewerURLMapper {
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
            let path = try requestPath(for: fileURL)
            if origin.scheme == Self.scheme {
                // Custom-scheme origin: the token already lives in the host
                // (`cmux-diff-viewer://<token>`), and the in-app scheme handler
                // looks up manifest entries by the RAW request path. So the URL
                // path must be exactly `requestPath`, NOT `/<token>/<requestPath>`
                // (which would be an unregistered double-token path). No history
                // marker fragment either, matching how restored scheme URLs are
                // built so `registeredFile(for:)` serves them.
                components.percentEncodedPath = path
                components.query = nil
                components.fragment = nil
            } else {
                // HTTP server origin: the token is path-based, so the served
                // path is `/<token>/<requestPath>`.
                components.percentEncodedPath = "/\(token)\(path)"
                components.query = nil
                components.fragment = Self.sessionHistoryMarker
            }
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
            var relativePath = String(filePath.dropFirst(rootPath.count + 1))
            if relativePath.hasSuffix(".deflate") {
                relativePath.removeLast(".deflate".count)
            }
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
        var protocolVersion: String?
        var executablePath: String?
    }

    private static let diffViewerHTTPServerProtocolVersion = "wait-v2 remote-stream manifest-refresh react-app-v2 executable-bound branch-picker-v1"
    private static let diffViewerHTTPServerHealthResponse = Data("ok \(diffViewerHTTPServerProtocolVersion)\n".utf8)

    /// Persisted, per-group session descriptor for the branch base picker. The
    /// `/__cmux_diff_viewer_branch` regenerate endpoint runs in the separate
    /// server process, which has none of the original `cmux diff` invocation's
    /// in-memory context. This record carries everything needed to regenerate a
    /// single branch page for an arbitrary base: the mapper token + groupID that
    /// key the output files into the secure dir, the repo allow-list the request
    /// is validated against, and the exact layout/appearance/title/workspace
    /// context so the regenerated page matches the original visually and
    /// behaviorally. Written next to the manifest as `.branch-session-<group>.json`.
    struct DiffViewerBranchSession: Codable {
        var token: String
        var groupID: String
        var repoRoot: String
        var allowedRepoRoots: [String]
        var layout: String
        var layoutSource: String
        var appearance: DiffViewerAppearance
        var titleOverride: String?
        var workspaceId: String?
        var surfaceId: String?
        /// repoRoot -> (DiffSource.slug -> sibling page FILE NAME, basename only,
        /// e.g. "diff-<group>-repo-1-branch.html"). Basenames are origin/port
        /// independent so they survive a server restart; URLs are rebuilt via the
        /// mapper at regenerate time. Defaults to empty so older session files
        /// (written before this field existed) still decode.
        var repoSourceFiles: [String: [String: String]]

        enum CodingKeys: String, CodingKey {
            case token
            case groupID
            case repoRoot
            case allowedRepoRoots
            case layout
            case layoutSource
            case appearance
            case titleOverride
            case workspaceId
            case surfaceId
            case repoSourceFiles
        }

        init(
            token: String,
            groupID: String,
            repoRoot: String,
            allowedRepoRoots: [String],
            layout: String,
            layoutSource: String,
            appearance: DiffViewerAppearance,
            titleOverride: String?,
            workspaceId: String?,
            surfaceId: String?,
            repoSourceFiles: [String: [String: String]] = [:]
        ) {
            self.token = token
            self.groupID = groupID
            self.repoRoot = repoRoot
            self.allowedRepoRoots = allowedRepoRoots
            self.layout = layout
            self.layoutSource = layoutSource
            self.appearance = appearance
            self.titleOverride = titleOverride
            self.workspaceId = workspaceId
            self.surfaceId = surfaceId
            self.repoSourceFiles = repoSourceFiles
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            token = try container.decode(String.self, forKey: .token)
            groupID = try container.decode(String.self, forKey: .groupID)
            repoRoot = try container.decode(String.self, forKey: .repoRoot)
            allowedRepoRoots = try container.decode([String].self, forKey: .allowedRepoRoots)
            layout = try container.decode(String.self, forKey: .layout)
            layoutSource = try container.decode(String.self, forKey: .layoutSource)
            appearance = try container.decode(DiffViewerAppearance.self, forKey: .appearance)
            titleOverride = try container.decodeIfPresent(String.self, forKey: .titleOverride)
            workspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId)
            surfaceId = try container.decodeIfPresent(String.self, forKey: .surfaceId)
            repoSourceFiles = try container.decodeIfPresent(
                [String: [String: String]].self,
                forKey: .repoSourceFiles
            ) ?? [:]
        }
    }

    struct DiffViewerLabels {
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
                "addComment": CMUXDiffViewerLocalization.string("diffViewer.addComment", defaultValue: "Add comment"),
                "bars": CMUXDiffViewerLocalization.string("diffViewer.bars", defaultValue: "Bars"),
                "binaryFile": CMUXDiffViewerLocalization.string("diffViewer.binaryFile", defaultValue: "Binary file"),
                "cancelComment": CMUXDiffViewerLocalization.string("diffViewer.cancelComment", defaultValue: "Cancel"),
                "comments": CMUXDiffViewerLocalization.string("diffViewer.comments", defaultValue: "Comments"),
                "commentPlaceholder": CMUXDiffViewerLocalization.string("diffViewer.commentPlaceholder", defaultValue: "Leave a comment"),
                "deleteComment": CMUXDiffViewerLocalization.string("diffViewer.deleteComment", defaultValue: "Delete"),
                "editComment": CMUXDiffViewerLocalization.string("diffViewer.editComment", defaultValue: "Edit"),
                "noComments": CMUXDiffViewerLocalization.string("diffViewer.noComments", defaultValue: "No comments yet"),
                "outdatedComment": CMUXDiffViewerLocalization.string("diffViewer.outdatedComment", defaultValue: "Outdated"),
                "saveComment": CMUXDiffViewerLocalization.string("diffViewer.saveComment", defaultValue: "Comment"),
                "changedFiles": CMUXDiffViewerLocalization.string("diffViewer.changedFiles", defaultValue: "Changed files"),
                "classic": CMUXDiffViewerLocalization.string("diffViewer.classic", defaultValue: "Classic"),
                "commit": CMUXDiffViewerLocalization.string("about.commit", defaultValue: "Commit"),
                "collapseAllDiffs": CMUXDiffViewerLocalization.string("diffViewer.collapseAllDiffs", defaultValue: "Collapse all diffs"),
                "collapseUnchangedContext": CMUXDiffViewerLocalization.string("diffViewer.collapseUnchangedContext", defaultValue: "Collapse unchanged context"),
                "copyFailedGitApplyCommand": CMUXDiffViewerLocalization.string("diffViewer.copyFailedGitApplyCommand", defaultValue: "Could not copy git apply command."),
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
                "modeChange": CMUXDiffViewerLocalization.string("diffViewer.modeChange", defaultValue: "Mode {old} → {new}"),
                "noFileDiffs": CMUXDiffViewerLocalization.string("diffViewer.noFileDiffs", defaultValue: "No file diffs found in patch input."),
                "none": CMUXDiffViewerLocalization.string("diffViewer.none", defaultValue: "None"),
                "openSourceURL": CMUXDiffViewerLocalization.string("diffViewer.openSourceURL", defaultValue: "Open source URL"),
                "options": CMUXDiffViewerLocalization.string("diffViewer.options", defaultValue: "Options"),
                "parsingDiff": CMUXDiffViewerLocalization.string("diffViewer.parsingDiff", defaultValue: "Parsing diff..."),
                "refresh": CMUXDiffViewerLocalization.string("diffViewer.refresh", defaultValue: "Refresh"),
                "renderingDiff": CMUXDiffViewerLocalization.string("diffViewer.renderingDiff", defaultValue: "Rendering diff..."),
                "repoPath": CMUXDiffViewerLocalization.string("diffViewer.repoPath", defaultValue: "Repository path"),
                "branchBase": CMUXDiffViewerLocalization.string("diffViewer.branchBase", defaultValue: "Branch base"),
                "branchPickerCurrent": CMUXDiffViewerLocalization.string("diffViewer.branchPickerCurrent", defaultValue: "current"),
                "branchPickerBasePrefix": CMUXDiffViewerLocalization.string("diffViewer.branchPickerBasePrefix", defaultValue: "Base:"),
                "branchPickerComparing": CMUXDiffViewerLocalization.string("diffViewer.branchPickerComparing", defaultValue: "Comparing {head} against {base}"),
                "branchPickerFilterPlaceholder": CMUXDiffViewerLocalization.string("diffViewer.branchPickerFilterPlaceholder", defaultValue: "Filter branches"),
                "branchPickerGenerateFailed": CMUXDiffViewerLocalization.string("diffViewer.branchPickerGenerateFailed", defaultValue: "Could not generate the diff. Choose a branch to retry."),
                "branchPickerGenerating": CMUXDiffViewerLocalization.string("diffViewer.branchPickerGenerating", defaultValue: "Generating diff against {ref}..."),
                "branchPickerGroupBranches": CMUXDiffViewerLocalization.string("diffViewer.branchPickerGroupBranches", defaultValue: "Branches"),
                "branchPickerGroupRecent": CMUXDiffViewerLocalization.string("diffViewer.branchPickerGroupRecent", defaultValue: "Recent"),
                "branchPickerGroupRemotes": CMUXDiffViewerLocalization.string("diffViewer.branchPickerGroupRemotes", defaultValue: "Remotes"),
                "branchPickerGroupSuggested": CMUXDiffViewerLocalization.string("diffViewer.branchPickerGroupSuggested", defaultValue: "Suggested"),
                "branchPickerGroupWorktrees": CMUXDiffViewerLocalization.string("diffViewer.branchPickerGroupWorktrees", defaultValue: "Worktrees"),
                "branchPickerLoadFailed": CMUXDiffViewerLocalization.string("diffViewer.branchPickerLoadFailed", defaultValue: "Could not load branches."),
                "branchPickerMore": CMUXDiffViewerLocalization.string("diffViewer.branchPickerMore", defaultValue: "{count} more, type to filter"),
                "branchPickerLoading": CMUXDiffViewerLocalization.string("diffViewer.branchPickerLoading", defaultValue: "Loading branches..."),
                "branchPickerNoMatches": CMUXDiffViewerLocalization.string("diffViewer.branchPickerNoMatches", defaultValue: "No matching branches"),
                "branchPickerOpen": CMUXDiffViewerLocalization.string("diffViewer.branchPickerOpen", defaultValue: "Change diff base"),
                "branchPickerUseRaw": CMUXDiffViewerLocalization.string("diffViewer.branchPickerUseRaw", defaultValue: "Use \"{ref}\" (raw)"),
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

    struct DiffViewerShortcutStroke: Equatable {
        var key: String
        var command: Bool
        var shift: Bool
        var option: Bool
        var control: Bool

        init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
            self.key = key
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
        }

        var jsonObject: [String: Any] {
            [
                "key": key,
                "command": command,
                "shift": shift,
                "option": option,
                "control": control,
            ]
        }
    }

    struct DiffViewerShortcut: Equatable {
        var first: DiffViewerShortcutStroke?
        var second: DiffViewerShortcutStroke?

        static let unbound = DiffViewerShortcut(first: nil, second: nil)

        var isUnbound: Bool { first == nil }

        var jsonObject: [String: Any] {
            if isUnbound {
                return ["unbound": true]
            }
            var object: [String: Any] = ["first": first?.jsonObject ?? [:]]
            if let second {
                object["second"] = second.jsonObject
            }
            return object
        }
    }

    enum DiffSource: CaseIterable, Equatable {
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

    struct DiffViewerAppearance: Codable {
        var backgroundOpacity: Double
        var fontFamily: String
        var fontSize: Double
        var lightTheme: DiffViewerTheme
        var darkTheme: DiffViewerTheme

        enum CodingKeys: String, CodingKey {
            case backgroundOpacity, fontFamily, fontSize, lightTheme, darkTheme
        }

        var lineHeight: Double {
            20
        }

        var diffHeaderHeight: Double {
            44
        }

        var jsonObject: [String: Any] {
            [
                "backgroundOpacity": backgroundOpacity,
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

    struct DiffViewerTheme: Codable {
        var generatedName: String
        var ghosttyName: String
        var type: String
        var background: String
        var foreground: String
        var selectionBackground: String
        var selectionForeground: String
        var palette: [Int: String]

        enum CodingKeys: String, CodingKey {
            case generatedName, ghosttyName, type, background, foreground
            case selectionBackground, selectionForeground, palette
        }

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

        let explicitFocus: Bool?
        if parsedArgs.noFocus {
            explicitFocus = false
        } else if let focusOpt = parsedArgs.focus {
            guard let parsed = parseBoolString(focusOpt) else {
                throw CLIError(message: "--focus must be true|false")
            }
            explicitFocus = parsed
        } else {
            explicitFocus = nil
        }
        let fileFocus = explicitFocus ?? true

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
        let shouldInheritCallerSurface = parsedArgs.workspace == nil && parsedArgs.pane == nil && parsedArgs.window == nil
        let surfaceRaw = parsedArgs.surface ?? (shouldInheritCallerSurface ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle, windowHandle: windowHandle)
        let paneHandle = try normalizePaneHandle(parsedArgs.pane, client: client, workspaceHandle: workspaceHandle)

        var payloads: [[String: Any]] = []

        var pendingFiles: [String] = []
        func flushPendingFiles() throws {
            guard !pendingFiles.isEmpty else { return }
            let files = pendingFiles
            pendingFiles.removeAll()

            var params: [String: Any] = ["paths": files, "focus": fileFocus]
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
            case .url(let url, let defaultFocus):
                try flushPendingFiles()
                var params: [String: Any] = ["url": url, "focus": explicitFocus ?? defaultFocus]
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

        let resolvedLayout = try resolveDiffViewerLayout(rawLayout: parsedArgs.layout)
        let layout = resolvedLayout.layout
        let layoutSource = resolvedLayout.source

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
            sessionId: parsedArgs.sessionId,
            repoRoot: nil,
            branchBaseRef: parsedArgs.branchBase
        )
        if let cwd = parsedArgs.cwd {
            diffSourceContext.repoRoot = try gitRepoRoot(startingAt: resolvePath(cwd))
        } else if parsedArgs.source == nil {
            // Piped patches get a best-effort repo root from the CLI's cwd so
            // diff comments can persist per repository.
            diffSourceContext.repoRoot = try? gitRepoRoot(
                startingAt: FileManager.default.currentDirectoryPath
            )
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
            sourceContext.sessionId = diffSourceContext.sessionId
            sourceContext.branchBaseRef = diffSourceContext.branchBaseRef
            diffSourceContext = sourceContext
            workspaceHandle = sourceContext.workspaceId ?? workspaceHandle
            surfaceHandle = sourceContext.surfaceId ?? surfaceHandle
        }

        let appearance = diffViewerAppearance(
            socketPath: socketPath,
            fontSizeOverride: fontSizeOverride
        )
        let runtime = diffViewerRuntime(socketPath: socketPath)
        let viewer = try writeDiffViewer(
            rawInput: parsedArgs.inputs.first,
            source: parsedArgs.source,
            titleOverride: parsedArgs.title,
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            context: diffSourceContext,
            runtime: runtime
        )

        try resolveTargetIfNeeded()
        let activeClient = try connectedClient()

        var params: [String: Any] = [
            "url": viewer.url.absoluteString,
            "focus": focus,
            "show_omnibar": false,
            "transparent_background": true,
            "bypass_remote_proxy": true
        ]
        params["diff_viewer_token"] = viewer.url.scheme == DiffViewerURLMapper.scheme ? (viewer.url.host ?? "") : (viewer.url.path.split(separator: "/").first.map(String.init) ?? "")
        if viewer.url.scheme == DiffViewerURLMapper.scheme {
            params["diff_viewer_files"] = viewer.allowedFiles.map(\.jsonObject)
        }
        if let windowHandle { params["window_id"] = windowHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let surfaceHandle { params["surface_id"] = surfaceHandle }

        let payload = try activeClient.sendV2(method: "browser.open_split", params: params)
        let completedViewer: DiffViewerWriteResult
        do {
            completedViewer = try completeDeferredDiffViewer(viewer)
        } catch {
            try navigateCompletedDiffViewerIfNeeded(
                viewer.completeDeferred != nil, viewer.url.scheme, payload,
                viewer.url, viewer.url, socketPath, explicitPassword
            )
            throw error
        }
        try navigateCompletedDiffViewerIfNeeded(
            viewer.completeDeferred != nil, viewer.url.scheme, payload,
            viewer.url, completedViewer.url, socketPath, explicitPassword
        )

        if jsonOutput {
            var response = payload
            response["path"] = completedViewer.fileURL.path
            response["url"] = completedViewer.url.absoluteString
            response["title"] = completedViewer.title
            response["source"] = completedViewer.input.sourceLabel
            print(jsonString(formatIDs(response, mode: idFormat)))
            return
        }

        let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
        let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
        print("OK surface=\(surfaceText) pane=\(paneText)")
    }

    private func diffViewerRuntime(socketPath: String) -> URL? {
        if let taggedExecutableURL = taggedDiffViewerExecutableURL(socketPath: socketPath) {
            return taggedExecutableURL
        }
        return nil
    }

    func diffViewerExecutableURL(for runtime: URL?) -> URL? {
        runtime ?? resolvedExecutableURL()
    }

    private func taggedDiffViewerExecutableURL(socketPath: String) -> URL? {
        let socketName = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefix = "cmux-debug-"
        let suffix = ".sock"
        guard socketName.hasPrefix(prefix), socketName.hasSuffix(suffix) else {
            return nil
        }

        let tagStart = socketName.index(socketName.startIndex, offsetBy: prefix.count)
        let tagEnd = socketName.index(socketName.endIndex, offsetBy: -suffix.count)
        let tag = String(socketName[tagStart..<tagEnd])
        guard !tag.isEmpty,
              tag.allSatisfy({ character in
                  character.isLetter || character.isNumber || character == "-" || character == "_"
              }) else {
            return nil
        }

        let homePath = ProcessInfo.processInfo.environment["HOME"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? NSHomeDirectory()
        let candidate = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Library/Developer/Xcode/DerivedData/cmux-\(tag)", isDirectory: true)
            .appendingPathComponent("Build/Products/Debug/cmux DEV \(tag).app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .standardizedFileURL

        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return nil
        }
        return canonicalFileURL(candidate)
    }

    private func canonicalFileURL(_ url: URL) -> URL {
        if let resolvedPath = realpath(url.path, nil) {
            defer { free(resolvedPath) }
            return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL
        }
        return url.standardizedFileURL
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
        return DiffSourceContext(workspaceId: workspaceId, surfaceId: surfaceId, sessionId: nil, repoRoot: nil, branchBaseRef: nil)
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
                case "--session", "--agent-session":
                    parsed.sessionId = try openOptionValue(commandArgs, index: index, name: arg)
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
                        throw CLIError(message: "diff: unknown flag '\(arg)'. Usage: cmux diff [patch-file|-] [--source <unstaged|staged|branch|last-turn>] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--session <id>] [--cwd <path>] [--base <ref>] [--focus true|false] [--no-focus] [--title <text>] [--layout split|unified] [--font-size <points>]")
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

    private func resolveDiffViewerLayout(rawLayout: String?) throws -> (layout: String, source: String) {
        if let rawLayout {
            return (try parseDiffViewerLayout(rawLayout, errorMessage: "--layout must be split|unified"), "explicit")
        }
        return (diffViewerDefaultLayoutSetting() ?? "unified", "default")
    }

    private func parseDiffViewerLayout(_ rawValue: String, errorMessage: String) throws -> String {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized == "split" || normalized == "unified" else {
            throw CLIError(message: errorMessage)
        }
        return normalized
    }

    private func diffViewerDefaultLayoutSetting() -> String? {
        for path in diffViewerDefaultSettingsPaths() {
            guard let root = diffViewerSettingsRoot(at: path),
                  let section = root["diffViewer"] as? [String: Any],
                  let rawLayout = section["defaultLayout"] as? String,
                  let layout = try? parseDiffViewerLayout(
                      rawLayout,
                      errorMessage: "diffViewer.defaultLayout must be split|unified"
                  ) else {
                continue
            }
            return layout
        }
        return nil
    }

    private func diffViewerDefaultSettingsPaths() -> [String] {
        [
            Self.primarySettingsDisplayPath,
            Self.legacySettingsDisplayPath,
            Self.fallbackSettingsDisplayPath,
        ].map(Self.absoluteDiffViewerSettingsPath)
    }

    private func diffViewerSettingsRoot(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty,
              let sanitized = try? JSONCParser.preprocess(data: data),
              let root = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any] else {
            return nil
        }
        return root
    }

    private func resolveOpenTarget(_ raw: String) throws -> OpenTarget {
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .url(url.absoluteString, defaultFocus: true)
        }

        let resolved = resolvePath(raw)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }

        if isDir.boolValue {
            return .directory(resolved)
        }
        let ext = URL(fileURLWithPath: resolved).pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            return .url(URL(fileURLWithPath: resolved).standardizedFileURL.absoluteString, defaultFocus: false)
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
            do {
                return DiffInput(
                    patch: "",
                    localPatchURL: try fetchDiffURLToFile(trustedRemoteURL, directory: diffViewerDirectory()),
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
                    patch: "",
                    localPatchURL: try fetchDiffURLToFile(url, directory: diffViewerDirectory()),
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

    func readGitDiffInput(source: DiffSource, context: DiffSourceContext) throws -> DiffInput {
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
            let sessionId = normalizedDiffSourceValue(context.sessionId)
            let env = ProcessInfo.processInfo.environment
            let baselineStorePath = CMUXAgentTurnDiffBaselineFile.path(env: env)
            if let record = try latestAgentTurnDiffBaseline(
                repoRoot: repoRoot,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                sessionId: sessionId,
                env: env
            ) {
                _ = try gitStdout(["cat-file", "-e", "\(record.baseCommit)^{tree}"], in: repoRoot)
                patch = try joinedGitDiffPatches([
                    gitStdout(gitDiffPatchArguments([record.baseCommit, "--"]), in: repoRoot),
                    gitUntrackedPatchSinceBaseline(record: record, in: repoRoot, storePath: baselineStorePath)
                ])
            } else {
                // No last-turn baseline recorded yet: emit an empty patch so the
                // viewer renders the friendly empty diff state (with the source
                // switcher) instead of throwing a developer-facing CLI error.
                patch = ""
            }
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

    func gitRepoRootForDiff(_ context: DiffSourceContext) throws -> String {
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
        throw CLIError(message: "Couldn't find a branch diff base. Set an upstream branch or create origin/main.")
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

    // MARK: - Branch base picker

    /// The chosen diff base plus why it was chosen and how much we trust it. The
    /// reason is one of the FROZEN-CONTRACT tags ("created from" | "PR base" |
    /// "fork point" | "default" | "manual"); confidence is "high" or "low".
    struct DiffBranchBase {
        var ref: String
        var reason: String
        var confidence: String
    }

    private enum DiffBranchBaseReason {
        static let createdFrom = "created from"
        static let prBase = "PR base"
        static let forkPoint = "fork point"
        static let `default` = "default"
        static let manual = "manual"
    }

    /// Localized, human-facing rendering of a reason tag for UI rows.
    func diffBranchBaseReasonLabel(_ reason: String) -> String {
        switch reason {
        case DiffBranchBaseReason.createdFrom:
            return CMUXDiffViewerLocalization.string("diffViewer.baseReason.createdFrom", defaultValue: "created from")
        case DiffBranchBaseReason.prBase:
            return CMUXDiffViewerLocalization.string("diffViewer.baseReason.prBase", defaultValue: "PR base")
        case DiffBranchBaseReason.forkPoint:
            return CMUXDiffViewerLocalization.string("diffViewer.baseReason.forkPoint", defaultValue: "fork point")
        case DiffBranchBaseReason.default:
            return CMUXDiffViewerLocalization.string("diffViewer.baseReason.default", defaultValue: "default")
        case DiffBranchBaseReason.manual:
            return CMUXDiffViewerLocalization.string("diffViewer.baseReason.manual", defaultValue: "manual")
        default:
            return reason
        }
    }

    /// The current branch short name, or nil for a detached HEAD.
    private func gitCurrentBranchName(in repoRoot: String) -> String? {
        guard let name = try? gitSingleLine(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot),
              !name.isEmpty,
              name != "HEAD" else {
            return nil
        }
        return name
    }

    private func gitRefExists(_ ref: String, in repoRoot: String) -> Bool {
        (try? gitStdout(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: repoRoot)) != nil
    }

    /// Resolve the smart default diff base for a branch source. When the caller
    /// passed an explicit `--base`, that is honored as a "manual" high-confidence
    /// choice. Otherwise walk the heuristic order: recorded cmuxBase -> PR base ->
    /// merge-base fork point -> origin/HEAD/main/master fallback.
    func resolvedDiffBranchBase(_ rawBaseRef: String?, in repoRoot: String) throws -> DiffBranchBase {
        if let rawBaseRef,
           !rawBaseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ref = try resolvedGitBranchDiffBaseRef(rawBaseRef, in: repoRoot)
            return DiffBranchBase(ref: ref, reason: DiffBranchBaseReason.manual, confidence: "high")
        }

        let branchName = gitCurrentBranchName(in: repoRoot)

        // 1. Recorded creation base written by new-cmux-worktree.sh. Read-only.
        if let branchName,
           let recorded = try? gitSingleLine(["config", "--get", "branch.\(branchName).cmuxBase"], in: repoRoot),
           !recorded.isEmpty,
           gitRefExists(recorded, in: repoRoot) {
            return DiffBranchBase(ref: recorded, reason: DiffBranchBaseReason.createdFrom, confidence: "high")
        }

        // 2. PR base via gh, best-effort and tolerant of gh missing / no PR.
        if let prBase = diffBranchBasePRBaseRef(in: repoRoot) {
            return DiffBranchBase(ref: prBase, reason: DiffBranchBaseReason.prBase, confidence: "high")
        }

        // 3. Configured upstream, but ONLY when it is an INTEGRATION branch, not
        // the branch's OWN remote tracking ref. A feature branch pushed with
        // `git push -u origin feature` has @{upstream} = origin/feature; using it
        // as the base would compare the branch against itself and hide every
        // already-pushed commit (showing only local unpushed work). Skip that
        // case and fall through to the default base. The rendered diff computes
        // `merge-base HEAD <base>` regardless, so a real integration upstream
        // still yields fork-point semantics.
        if let branchName,
           let upstream = try? gitSingleLine(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            in: repoRoot
        ), !upstream.isEmpty,
           // Strip ONLY the remote prefix (first segment); the branch part can
           // itself contain slashes (e.g. origin/feature/foo). Compare the whole
           // remainder to the current branch name so `feature/foo` tracking
           // `origin/feature/foo` is correctly recognized as its own remote ref.
           String(upstream.drop(while: { $0 != "/" }).dropFirst()) != branchName,
           gitRefExists(upstream, in: repoRoot) {
            return DiffBranchBase(ref: upstream, reason: DiffBranchBaseReason.forkPoint, confidence: "high")
        }

        // 4. origin/HEAD -> origin/main -> master fallback. Low confidence: a guess.
        let fallback = try gitBranchDiffBaseRef(in: repoRoot)
        return DiffBranchBase(ref: fallback, reason: DiffBranchBaseReason.default, confidence: "low")
    }

    /// Process-level memo for `diffBranchBasePRBaseRef`. The diff-viewer HTTP
    /// server dispatches requests on concurrent queues and a single refs build
    /// resolves the PR base twice (heuristic chain + explicit Suggested row), so
    /// without this the ~0.7s `gh pr view` round-trip runs 2x per popover open
    /// and again on every reopen. Entries store the resolved ref AND the nil
    /// outcome (a repo with no PR is not re-queried) under a short TTL. Guarded
    /// by `os_unfair_lock` since callers run on concurrent dispatch queues.
    private enum DiffBranchBasePRCache {
        struct Entry {
            var value: String?
            var storedAt: TimeInterval
        }

        static let ttl: TimeInterval = 30
        private static var lock = os_unfair_lock()
        private static var entries: [String: Entry] = [:]

        /// Returns `.some(value)` on a fresh hit (value may itself be `nil`,
        /// meaning "no PR base"), or `nil` on a miss/expiry so the caller
        /// recomputes.
        static func lookup(_ repoRoot: String, now: TimeInterval) -> String?? {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            guard let entry = entries[repoRoot], now - entry.storedAt <= ttl else {
                return nil
            }
            return .some(entry.value)
        }

        static func store(_ repoRoot: String, value: String?, now: TimeInterval) {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            entries[repoRoot] = Entry(value: value, storedAt: now)
        }
    }

    /// Best-effort PR base branch via `gh pr view`. Returns nil when gh is
    /// missing, unauthenticated, there is no PR, or the base ref is unknown
    /// locally. A short timeout keeps the picker responsive offline. Memoized at
    /// process scope (see `DiffBranchBasePRCache`) so redundant calls within and
    /// across refs requests collapse to one network round-trip. The observable
    /// result is unchanged; only timing differs.
    private func diffBranchBasePRBaseRef(in repoRoot: String) -> String? {
        let now = Date().timeIntervalSince1970
        if let cached = DiffBranchBasePRCache.lookup(repoRoot, now: now) {
            return cached
        }
        let value = computeDiffBranchBasePRBaseRef(in: repoRoot)
        DiffBranchBasePRCache.store(repoRoot, value: value, now: now)
        return value
    }

    /// Uncached `gh pr view` resolution. Do not call directly; go through
    /// `diffBranchBasePRBaseRef` so the process-level memo applies.
    private func computeDiffBranchBasePRBaseRef(in repoRoot: String) -> String? {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "gh", "pr", "view",
                "--json", "baseRefName",
                "--jq", ".baseRefName"
            ],
            currentDirectoryPath: repoRoot,
            timeout: 4
        )
        guard !result.timedOut, result.status == 0 else { return nil }
        let base = result.stdout
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !base.isEmpty else { return nil }
        // gh returns the bare base branch name (e.g. "main"); prefer the
        // remote-tracking ref when present so the diff is against what was pushed.
        for candidate in ["origin/\(base)", base] {
            if gitRefExists(candidate, in: repoRoot) {
                return candidate
            }
        }
        return nil
    }

    private struct DiffBranchAheadBehind {
        var ahead: Int
        var behind: Int
    }

    /// `git rev-list --left-right --count <base>...HEAD` -> behind (left, in base
    /// not HEAD) and ahead (right, in HEAD not base). Tolerates failure -> nil.
    private func diffBranchAheadBehind(base: String, in repoRoot: String) -> DiffBranchAheadBehind? {
        guard let line = try? gitSingleLine(
            ["rev-list", "--left-right", "--count", "\(base)...HEAD"],
            in: repoRoot
        ) else {
            return nil
        }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else {
            return nil
        }
        return DiffBranchAheadBehind(ahead: ahead, behind: behind)
    }

    // MARK: - Uncapped grouped refs listing

    private struct DiffBranchRefRow {
        var ref: String
        var label: String
        var secondary: String?
        var reason: String?
        var confidence: String?
        var current: Bool?
        var worktreeDir: String?

        var jsonObject: [String: Any] {
            var object: [String: Any] = ["ref": ref, "label": label]
            if let secondary { object["secondary"] = secondary }
            if let reason { object["reason"] = reason }
            if let confidence { object["confidence"] = confidence }
            if let current { object["current"] = current }
            if let worktreeDir { object["worktreeDir"] = worktreeDir }
            return object
        }
    }

    private struct DiffBranchRefGroup {
        var id: String
        var label: String
        var rows: [DiffBranchRefRow]

        var jsonObject: [String: Any] {
            ["id": id, "label": label, "rows": rows.map(\.jsonObject)]
        }
    }

    /// Build the uncapped, grouped refs listing for the picker. Groups are in the
    /// FROZEN order suggested|worktrees|branches|remotes|recent; empty groups are
    /// omitted by the caller's JSON assembly. The Suggested section (heuristic
    /// default bases) and every section after it are DISJOINT: a ref surfaced in
    /// Suggested is removed from worktrees/branches/remotes/recent, so a user can
    /// read the top section as "the picker's nondeterministic guesses" without
    /// seeing the same ref repeated in the deterministic lists below.
    private func diffBranchRefGroups(in repoRoot: String, selectedBaseRef: String?) -> [DiffBranchRefGroup] {
        let currentBranch = gitCurrentBranchName(in: repoRoot)
        var groups: [DiffBranchRefGroup] = []

        // Safety bound on the branches/remotes scans so a pathological repo (tens
        // of thousands of refs) cannot make a single popover open allocate, cache,
        // and transfer an unbounded payload. Generous enough to stay effectively
        // uncapped for any realistic repo; `git for-each-ref --count` limits the
        // work at the source rather than after building the full array.
        let maxRefsPerGroup = 5000

        // Suggested: the heuristic bases, deduped, each with reason/confidence.
        var suggestedRows: [DiffBranchRefRow] = []
        var suggestedSeen: Set<String> = []
        func appendSuggested(_ base: DiffBranchBase?) {
            guard let base, !suggestedSeen.contains(base.ref) else { return }
            suggestedSeen.insert(base.ref)
            suggestedRows.append(
                DiffBranchRefRow(
                    ref: base.ref,
                    label: base.ref,
                    secondary: diffBranchBaseReasonLabel(base.reason),
                    reason: base.reason,
                    confidence: base.confidence,
                    current: nil,
                    worktreeDir: nil
                )
            )
        }
        if let selectedBaseRef, !selectedBaseRef.isEmpty, gitRefExists(selectedBaseRef, in: repoRoot) {
            appendSuggested(DiffBranchBase(ref: selectedBaseRef, reason: DiffBranchBaseReason.manual, confidence: "high"))
        }
        appendSuggested(try? resolvedDiffBranchBase(nil, in: repoRoot))
        // Surface each individual heuristic source so cmuxBase and PR base can
        // both appear when they disagree (LOCKED DECISION).
        if let branchName = currentBranch,
           let recorded = try? gitSingleLine(["config", "--get", "branch.\(branchName).cmuxBase"], in: repoRoot),
           !recorded.isEmpty, gitRefExists(recorded, in: repoRoot) {
            appendSuggested(DiffBranchBase(ref: recorded, reason: DiffBranchBaseReason.createdFrom, confidence: "high"))
        }
        if let prBase = diffBranchBasePRBaseRef(in: repoRoot) {
            appendSuggested(DiffBranchBase(ref: prBase, reason: DiffBranchBaseReason.prBase, confidence: "high"))
        }
        if !suggestedRows.isEmpty {
            groups.append(
                DiffBranchRefGroup(
                    id: "suggested",
                    label: CMUXDiffViewerLocalization.string("diffViewer.refGroup.suggested", defaultValue: "Suggested"),
                    rows: suggestedRows
                )
            )
        }

        // Worktrees: sibling task branches, dir basename as worktreeDir. Skip the
        // current worktree and any bare entry.
        var worktreeRows: [DiffBranchRefRow] = []
        if let porcelain = try? gitStdout(["worktree", "list", "--porcelain"], in: repoRoot) {
            var currentDir: String?
            var currentBranchRef: String?
            var isBare = false
            func flush() {
                defer { currentDir = nil; currentBranchRef = nil; isBare = false }
                guard !isBare,
                      let dir = currentDir,
                      let branchRef = currentBranchRef else { return }
                let standardizedDir = URL(fileURLWithPath: dir).standardizedFileURL.resolvingSymlinksInPath().path
                let standardizedRepo = URL(fileURLWithPath: repoRoot).standardizedFileURL.resolvingSymlinksInPath().path
                guard standardizedDir != standardizedRepo else { return }
                let short = branchRef.hasPrefix("refs/heads/")
                    ? String(branchRef.dropFirst("refs/heads/".count))
                    : branchRef
                guard !suggestedSeen.contains(short) else { return }
                worktreeRows.append(
                    DiffBranchRefRow(
                        ref: short,
                        label: short,
                        secondary: URL(fileURLWithPath: dir).lastPathComponent,
                        reason: nil,
                        confidence: nil,
                        current: nil,
                        worktreeDir: URL(fileURLWithPath: dir).lastPathComponent
                    )
                )
            }
            for line in porcelain.components(separatedBy: .newlines) {
                if line.hasPrefix("worktree ") {
                    flush()
                    currentDir = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("branch ") {
                    currentBranchRef = String(line.dropFirst("branch ".count))
                } else if line == "bare" {
                    isBare = true
                } else if line.isEmpty {
                    flush()
                }
            }
            flush()
        }
        if !worktreeRows.isEmpty {
            groups.append(
                DiffBranchRefGroup(
                    id: "worktrees",
                    label: CMUXDiffViewerLocalization.string("diffViewer.refGroup.worktrees", defaultValue: "Worktrees"),
                    rows: worktreeRows
                )
            )
        }

        // Branches: local heads with last-commit relative time, current marked.
        var branchRows: [DiffBranchRefRow] = []
        if let listing = try? gitStdout(
            ["for-each-ref", "--count=\(maxRefsPerGroup)", "--format=%(refname:short)%09%(committerdate:relative)", "refs/heads"],
            in: repoRoot
        ) {
            for line in listing.split(whereSeparator: \.isNewline).map(String.init) {
                let fields = line.components(separatedBy: "\t")
                let ref = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !ref.isEmpty, !suggestedSeen.contains(ref) else { continue }
                let relative = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                branchRows.append(
                    DiffBranchRefRow(
                        ref: ref,
                        label: ref,
                        secondary: relative.isEmpty ? nil : relative,
                        reason: nil,
                        confidence: nil,
                        current: ref == currentBranch ? true : nil,
                        worktreeDir: nil
                    )
                )
            }
        }
        if !branchRows.isEmpty {
            groups.append(
                DiffBranchRefGroup(
                    id: "branches",
                    label: CMUXDiffViewerLocalization.string("diffViewer.refGroup.branches", defaultValue: "Branches"),
                    rows: branchRows
                )
            )
        }

        // Remotes: refs/remotes minus the */HEAD pointers.
        var remoteRows: [DiffBranchRefRow] = []
        if let listing = try? gitStdout(
            ["for-each-ref", "--count=\(maxRefsPerGroup)", "--format=%(refname:short)", "refs/remotes"],
            in: repoRoot
        ) {
            for line in listing.split(whereSeparator: \.isNewline).map(String.init) {
                let ref = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ref.isEmpty, !ref.hasSuffix("/HEAD"), !suggestedSeen.contains(ref) else { continue }
                remoteRows.append(
                    DiffBranchRefRow(ref: ref, label: ref, secondary: nil, reason: nil, confidence: nil, current: nil, worktreeDir: nil)
                )
            }
        }
        if !remoteRows.isEmpty {
            groups.append(
                DiffBranchRefGroup(
                    id: "remotes",
                    label: CMUXDiffViewerLocalization.string("diffViewer.refGroup.remotes", defaultValue: "Remotes"),
                    rows: remoteRows
                )
            )
        }

        // Recent: distinct branches recently checked out, from reflog. Capped ~8.
        var recentRows: [DiffBranchRefRow] = []
        var recentSeen: Set<String> = []
        if let reflog = try? gitStdout(
            ["reflog", "--format=%gs", "-n", "200"],
            in: repoRoot
        ) {
            for line in reflog.split(whereSeparator: \.isNewline).map(String.init) {
                guard recentRows.count < 8 else { break }
                // "checkout: moving from X to Y" -> Y is the checked-out ref.
                guard line.hasPrefix("checkout: moving from "),
                      let range = line.range(of: " to ", options: .backwards) else { continue }
                let ref = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ref.isEmpty,
                      ref != currentBranch,
                      !recentSeen.contains(ref),
                      !suggestedSeen.contains(ref),
                      gitRefExists(ref, in: repoRoot) else { continue }
                recentSeen.insert(ref)
                recentRows.append(
                    DiffBranchRefRow(ref: ref, label: ref, secondary: nil, reason: nil, confidence: nil, current: nil, worktreeDir: nil)
                )
            }
        }
        if !recentRows.isEmpty {
            groups.append(
                DiffBranchRefGroup(
                    id: "recent",
                    label: CMUXDiffViewerLocalization.string("diffViewer.refGroup.recent", defaultValue: "Recent"),
                    rows: recentRows
                )
            )
        }

        return groups
    }

    // MARK: - Stale-while-revalidate refs cache

    /// On-disk payload format for the refs cache. `groupsJSON` holds the exact
    /// serialized `groups` array (`[[String: Any]]` encoded with `.sortedKeys`),
    /// so re-embedding it under `{"groups": ...}` reproduces byte-identical
    /// output to a fresh compute. Bump `schemaVersion` on any shape change so old
    /// files are ignored rather than mis-decoded.
    private struct DiffBranchRefsCacheFile: Codable {
        static let currentSchemaVersion = 1
        var schemaVersion: Int
        var computedAt: Double
        var repoRoot: String
        /// The serialized `groups` array (NOT the full `{"groups": ...}` payload).
        var groupsJSON: Data
    }

    /// Process-level dedupe of background refresh work and the lock guarding the
    /// in-flight set. A separate refresh per (repoRoot, base) key avoids
    /// recomputing the same refs many times when a burst of popover opens lands
    /// within the TTL window.
    private enum DiffBranchRefsCacheState {
        /// How long a cached payload is served before a background refresh is
        /// kicked off (HTTP path) or a synchronous recompute happens (CLI path).
        static let ttl: TimeInterval = 20
        private static var lock = os_unfair_lock()
        private static var refreshing: Set<String> = []

        /// Try to claim a refresh for `key`. Returns true if the caller now owns
        /// the refresh (no other refresh in flight), false to skip (dogpile
        /// prevention).
        static func beginRefresh(_ key: String) -> Bool {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            if refreshing.contains(key) { return false }
            refreshing.insert(key)
            return true
        }

        static func endRefresh(_ key: String) {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            refreshing.remove(key)
        }
    }

    /// Lowercase-hex encode bytes WITHOUT `String(format: "%02x", ...)`. The
    /// Foundation/C `String(format:)` path is the unbounded-memory-growth/crash
    /// pattern fixed in https://github.com/manaflow-ai/cmux/pull/5347, and these
    /// digests run from the concurrent HTTP picker endpoints + scheme handler.
    /// This is byte-identical to the old `map { String(format: "%02x", $0) }
    /// .joined()` output (same SHA-256 bytes -> same hex), so cache filenames and
    /// slugs stay stable.
    private func diffBranchHexEncoded<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
        var chars: [Character] = []
        for byte in bytes {
            chars.append(digits[Int(byte >> 4)])
            chars.append(digits[Int(byte & 0x0F)])
        }
        return String(chars)
    }

    /// Cache key folds repoRoot and the selected base together so a different
    /// selected base never serves a wrong Suggested row. The HTTP refs route
    /// passes no base today (nil), so its key is repoRoot-only.
    private func diffBranchRefsCacheKey(repoRoot: String, selectedBaseRef: String?) -> String {
        if let selectedBaseRef, !selectedBaseRef.isEmpty {
            return repoRoot + "\u{0}" + selectedBaseRef
        }
        return repoRoot
    }

    private func diffBranchRefsCacheURL(
        repoRoot: String,
        selectedBaseRef: String?,
        rootDirectory: URL
    ) -> URL {
        var hasher = SHA256()
        hasher.update(data: Data(diffBranchRefsCacheKey(
            repoRoot: repoRoot,
            selectedBaseRef: selectedBaseRef
        ).utf8))
        let digest = diffBranchHexEncoded(hasher.finalize())
        return rootDirectory.appendingPathComponent(".refs-cache-\(digest).json", isDirectory: false)
    }

    /// Serialize `groups` exactly as the endpoints do (`[[String: Any]]` with
    /// `.sortedKeys`). This is the inner array; the endpoint wraps it as
    /// `{"groups": <this>}`.
    private func diffBranchRefGroupsArrayData(_ groups: [DiffBranchRefGroup]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: groups.map(\.jsonObject),
            options: [.sortedKeys]
        )
    }

    /// Wrap a serialized groups array into the final `{"groups": ...}` payload
    /// with byte layout identical to a direct `JSONSerialization` of the whole
    /// object: `.sortedKeys` orders the single top-level key deterministically
    /// and `JSONSerialization` emits no insignificant whitespace.
    private func diffBranchRefsPayloadData(fromGroupsArray groupsArray: Data) -> Data {
        var payload = Data("{\"groups\":".utf8)
        payload.append(groupsArray)
        payload.append(Data("}".utf8))
        return payload
    }

    /// Read + validate a cache file. Returns nil on any problem (missing,
    /// unreadable, corrupt JSON, schema mismatch, repoRoot mismatch) so the
    /// caller recomputes. Never throws, never serves garbage.
    private func readDiffBranchRefsCache(
        repoRoot: String,
        selectedBaseRef: String?,
        rootDirectory: URL
    ) -> DiffBranchRefsCacheFile? {
        let url = diffBranchRefsCacheURL(
            repoRoot: repoRoot,
            selectedBaseRef: selectedBaseRef,
            rootDirectory: rootDirectory
        )
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(DiffBranchRefsCacheFile.self, from: data),
              file.schemaVersion == DiffBranchRefsCacheFile.currentSchemaVersion,
              file.repoRoot == repoRoot else {
            return nil
        }
        return file
    }

    /// Atomically write the refs cache with 0600 perms, matching the security
    /// posture of `.branch-session-*.json` and `.server.json`. Best-effort: a
    /// write failure just means the next request recomputes.
    private func writeDiffBranchRefsCache(
        groupsArray: Data,
        repoRoot: String,
        selectedBaseRef: String?,
        computedAt: Double,
        rootDirectory: URL
    ) {
        let file = DiffBranchRefsCacheFile(
            schemaVersion: DiffBranchRefsCacheFile.currentSchemaVersion,
            computedAt: computedAt,
            repoRoot: repoRoot,
            groupsJSON: groupsArray
        )
        let url = diffBranchRefsCacheURL(
            repoRoot: repoRoot,
            selectedBaseRef: selectedBaseRef,
            rootDirectory: rootDirectory
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Compute the refs groups, serialize the array, and write the cache. Shared
    /// by the synchronous-miss path and the background refresh. Returns the
    /// serialized groups array on success.
    @discardableResult
    private func computeAndCacheDiffBranchRefs(
        repoRoot: String,
        selectedBaseRef: String?,
        rootDirectory: URL
    ) -> Data? {
        let groups = diffBranchRefGroups(in: repoRoot, selectedBaseRef: selectedBaseRef)
        guard let groupsArray = try? diffBranchRefGroupsArrayData(groups) else { return nil }
        writeDiffBranchRefsCache(
            groupsArray: groupsArray,
            repoRoot: repoRoot,
            selectedBaseRef: selectedBaseRef,
            computedAt: Date().timeIntervalSince1970,
            rootDirectory: rootDirectory
        )
        return groupsArray
    }

    /// Stale-while-revalidate refs payload for the long-lived HTTP server.
    /// Returns the final `{"groups": ...}` payload Data, byte-identical to an
    /// uncached build. On a cache hit it returns immediately; if the entry is
    /// older than the TTL it additionally kicks off a background recompute that
    /// atomically rewrites the cache (deduped so concurrent opens don't stampede
    /// git). On a miss it computes synchronously, writes the cache, and returns.
    func cachedDiffBranchRefGroupsPayloadForHTTP(
        repoRoot: String,
        selectedBaseRef: String?,
        rootDirectory: URL
    ) -> Data {
        if let cached = readDiffBranchRefsCache(
            repoRoot: repoRoot,
            selectedBaseRef: selectedBaseRef,
            rootDirectory: rootDirectory
        ) {
            let payload = diffBranchRefsPayloadData(fromGroupsArray: cached.groupsJSON)
            if Date().timeIntervalSince1970 - cached.computedAt > DiffBranchRefsCacheState.ttl {
                let key = diffBranchRefsCacheKey(repoRoot: repoRoot, selectedBaseRef: selectedBaseRef)
                if DiffBranchRefsCacheState.beginRefresh(key) {
                    DispatchQueue.global(qos: .utility).async {
                        defer { DiffBranchRefsCacheState.endRefresh(key) }
                        self.computeAndCacheDiffBranchRefs(
                            repoRoot: repoRoot,
                            selectedBaseRef: selectedBaseRef,
                            rootDirectory: rootDirectory
                        )
                    }
                }
            }
            return payload
        }

        // Miss: compute synchronously, write, return. Fall back to a direct
        // build if serialization of the cache array somehow fails.
        if let groupsArray = computeAndCacheDiffBranchRefs(
            repoRoot: repoRoot,
            selectedBaseRef: selectedBaseRef,
            rootDirectory: rootDirectory
        ) {
            return diffBranchRefsPayloadData(fromGroupsArray: groupsArray)
        }
        let groups = diffBranchRefGroups(in: repoRoot, selectedBaseRef: selectedBaseRef)
        let payload: [String: Any] = ["groups": groups.map(\.jsonObject)]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("{\"groups\":[]}".utf8)
    }

    /// Cache-aware refs payload for the one-shot CLI/custom-scheme path. This
    /// process exits right after responding, so a background thread would be
    /// killed mid-flight: serve a fresh-enough cache (< TTL) if present, else
    /// compute synchronously and write the cache. No background refresh.
    func cachedDiffBranchRefGroupsPayloadForCLI(
        repoRoot: String,
        selectedBaseRef: String?,
        rootDirectory: URL
    ) -> Data {
        if let cached = readDiffBranchRefsCache(
            repoRoot: repoRoot,
            selectedBaseRef: selectedBaseRef,
            rootDirectory: rootDirectory
        ), Date().timeIntervalSince1970 - cached.computedAt <= DiffBranchRefsCacheState.ttl {
            return diffBranchRefsPayloadData(fromGroupsArray: cached.groupsJSON)
        }
        if let groupsArray = computeAndCacheDiffBranchRefs(
            repoRoot: repoRoot,
            selectedBaseRef: selectedBaseRef,
            rootDirectory: rootDirectory
        ) {
            return diffBranchRefsPayloadData(fromGroupsArray: groupsArray)
        }
        let groups = diffBranchRefGroups(in: repoRoot, selectedBaseRef: selectedBaseRef)
        let payload: [String: Any] = ["groups": groups.map(\.jsonObject)]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("{\"groups\":[]}".utf8)
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

    /// Returns the most recent last-turn diff baseline recorded for the given
    /// workspace/surface, or `nil` when no baseline has been recorded yet.
    ///
    /// A missing baseline is not an error: it means there is simply nothing to
    /// diff for the last turn, so callers render the friendly empty diff state
    /// (with the source switcher) rather than surfacing a raw CLI error.
    private func latestAgentTurnDiffBaseline(
        repoRoot: String,
        workspaceId: String,
        surfaceId: String,
        sessionId: String?,
        env: [String: String]
    ) throws -> CMUXAgentTurnDiffBaselineRecord? {
        let store = try readAgentTurnDiffBaselineStore(path: CMUXAgentTurnDiffBaselineFile.path(env: env))
        let repoRoot = standardizedDiffSourcePath(repoRoot)
        let candidates = store.records.filter { record in
            standardizedDiffSourcePath(record.repoRoot) == repoRoot
                && diffScopeIdentifierEquals(record.workspaceId, workspaceId)
                && diffScopeIdentifierEquals(record.surfaceId, surfaceId)
                && (sessionId == nil || record.sessionId == sessionId)
        }
        return candidates.max(by: { $0.capturedAt < $1.capturedAt })
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

    func normalizedDiffSourceValue(_ value: String?) -> String? {
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
            backgroundOpacity: 1,
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
            case "background-opacity":
                if let backgroundOpacity = diffViewerConfigUnitInterval(value) {
                    appearance.backgroundOpacity = backgroundOpacity
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

    private func diffViewerConfigUnitInterval(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let rawNumber: String
        let divisor: Double
        if trimmed.hasSuffix("%") {
            rawNumber = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            divisor = 100
        } else {
            rawNumber = trimmed
            divisor = 1
        }
        guard let value = Double(rawNumber), value.isFinite else { return nil }

        return roundedDiffViewerMetric(min(1, max(0, value / divisor)))
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
        layoutSource: String,
        appearance: DiffViewerAppearance,
        context: DiffSourceContext,
        runtime: URL?
    ) throws -> DiffViewerWriteResult {
        if let source {
            return try writeGitDiffViewerHTMLSet(
                selectedSource: source,
                titleOverride: titleOverride,
                layout: layout,
                layoutSource: layoutSource,
                appearance: appearance,
                context: context,
                runtime: runtime
            )
        }

        let input = try readDiffInput(rawInput, source: nil, context: context)
        defer {
            if let localPatchURL = input.localPatchURL { try? FileManager.default.removeItem(at: localPatchURL) }
        }
        if input.localPatchURL == nil && input.remotePatchURL == nil {
            let trimmedPatch = input.patch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPatch.isEmpty else {
                throw CLIError(message: input.emptyMessage ?? "diff input is empty")
            }
        }

        let title = titleOverride ?? input.defaultTitle
        let directory = try diffViewerDirectory()
        let token = UUID().uuidString.lowercased()
        guard let origin = URL(string: "\(DiffViewerURLMapper.scheme)://\(token)") else {
            throw CLIError(message: "Failed to build diff viewer scheme origin")
        }
        let mapper = DiffViewerURLMapper(
            token: token,
            rootDirectory: directory,
            origin: origin
        )
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "diff-\(timestamp)-\(UUID().uuidString.prefix(8)).html"
        let viewerFileURL = directory.appendingPathComponent(filename, isDirectory: false)
        try writeDiffViewerHTML(
            to: viewerFileURL,
            patch: input.patch,
            localPatchURL: input.localPatchURL,
            title: title,
            sourceLabel: input.sourceLabel,
            externalURL: input.externalURL,
            remotePatchURL: input.remotePatchURL,
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            sourceOptions: [],
            repoRoot: context.repoRoot,
            runtime: runtime
        )
        let assets = try ensureDiffViewerAssets(nextTo: viewerFileURL, runtime: runtime)
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
        layoutSource: String,
        appearance: DiffViewerAppearance,
        context: DiffSourceContext,
        runtime: URL?
    ) throws -> DiffViewerWriteResult {
        let target = try makeDiffViewerGitHTMLSetTarget(runtime: runtime)
        if selectedSource != .lastTurn,
           !diffViewerUsesTypedSidecar(runtime: target.runtime) {
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
        let token = UUID().uuidString.lowercased()
        guard let origin = URL(string: "\(DiffViewerURLMapper.scheme)://\(token)") else {
            throw CLIError(message: "Failed to build diff viewer scheme origin")
        }
        let mapper = DiffViewerURLMapper(
            token: token,
            rootDirectory: directory,
            origin: origin
        )
        let timestamp = Int(Date().timeIntervalSince1970)
        let groupID = "\(timestamp)-\(UUID().uuidString.prefix(8))"
        return DiffViewerGitHTMLSetTarget(directory: directory, mapper: mapper, groupID: groupID, runtime: runtime)
    }

    func diffViewerLoadingDiffMessage(_ target: String) -> String {
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
        try writeDiffViewerOpeningHTML(
            to: openingFileURL,
            title: title,
            message: message,
            appearance: appearance
        )
        let allowedFiles = [try mapper.allowedFile(fileURL: openingFileURL, mimeType: "text/html")]
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
                    if !diffViewerUsesTypedSidecar(runtime: target.runtime) {
                        var finalized = completed
                        var completedPageURLs = Set<URL>()
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
                    }
                    try writeDiffViewerRedirectHTML(
                        to: openingFileURL,
                        title: completed.title,
                        targetURL: completed.url,
                        appearance: appearance,
                        runtime: target.runtime
                    )
                    return completed
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
        if diffViewerUsesTypedSidecar(runtime: target.runtime) {
            return try writeTypedGitDiffViewerPage(
                selectedSource: selectedSource,
                titleOverride: titleOverride,
                layout: layout,
                layoutSource: layoutSource,
                appearance: appearance,
                context: context,
                target: target,
                extraAllowedPageURL: extraAllowedPageURL
            )
        }
        let directory = target.directory
        let mapper = target.mapper
        let groupID = target.groupID
        let requestedSource = selectedSource
        let repoRoot = try gitRepoRootForDiff(context)
        let explicitBranchBaseRef = normalizedDiffSourceValue(context.branchBaseRef)
        var selectedSource = requestedSource
        let shouldDeferSelectedSource = requestedSource != .lastTurn
        // Smart branch base is the single source of truth for the rendered branch
        // diff AND the embedded picker, so the toolbar's advertised base always
        // equals the base the diff was actually computed against. When an explicit
        // `--base` was passed it stays "manual"/high-confidence and is honored
        // verbatim. With no explicit base, the heuristic resolver (cmuxBase -> PR
        // base -> fork point -> origin/HEAD fallback) picks the ref; the legacy
        // `resolvedGitBranchDiffBaseRef` is only the resolver's own last-resort
        // fallback, so it never independently overrides the smart choice here.
        // Cache per repoRoot so the heuristic (which can shell out to `gh`) runs at
        // most once per repo and the primary repo's full DiffBranchBase (with its
        // reason/confidence) is reused for the picker payload.
        var smartBranchBaseByRepo: [String: DiffBranchBase] = [:]
        func smartBranchBase(in repoRoot: String) -> DiffBranchBase? {
            if let cached = smartBranchBaseByRepo[repoRoot] { return cached }
            guard let resolved = try? resolvedDiffBranchBase(explicitBranchBaseRef, in: repoRoot) else {
                return nil
            }
            smartBranchBaseByRepo[repoRoot] = resolved
            return resolved
        }
        func sourceContext(for source: DiffSource, repoRoot: String) throws -> DiffSourceContext {
            var sourceContext = context
            sourceContext.repoRoot = repoRoot
            if source == .branch {
                // Prefer the smart-resolved base so the rendered diff agrees with
                // the picker's currentRef; fall back to the legacy resolver only if
                // the smart resolver yields nothing.
                if let smart = smartBranchBase(in: repoRoot) {
                    sourceContext.branchBaseRef = smart.ref
                } else {
                    sourceContext.branchBaseRef = try resolvedGitBranchDiffBaseRef(
                        sourceContext.branchBaseRef,
                        in: repoRoot
                    )
                }
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
        // All source/repo/base shells share one immutable asset set. Resolving
        // it once avoids re-hashing the multi-megabyte web bundle for every
        // lazy page descriptor (44 pages in a typical super-repo workspace).
        let sharedAssets = try ensureDiffViewerAssets(
            nextTo: selectedFileURL,
            runtime: target.runtime
        )
        let sharedPayload = DiffViewerSharedPayload(
            labels: DiffViewerLabels.localized().jsonObject,
            shortcuts: diffViewerShortcutPayload(),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
        let repoCandidates = gitDiffViewerRepoOptions(selectedRepoRoot: repoRoot, context: context)
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

        // Smart-default base with reason/confidence for the selected branch page.
        // Resolve from the originally requested base (not the already-resolved
        // ref) so the heuristic reason ("created from"/"PR base"/"fork point"/
        // "default"/"manual") is preserved. Persist a session descriptor keyed by
        // groupID so the regenerate endpoint in the server process can rebuild a
        // branch page for any base without the original invocation's context.
        // The base used to embed the branchPicker payload. Cleared to nil if the
        // session descriptor write fails, because the branchPicker payload
        // (refsURL/regenerateURLTemplate) drives endpoints that read that session
        // file; if the write failed those endpoints 404, so omit the payload and
        // let the page fall back to the legacy base `<select>`.
        var selectedBranchBase = branchBaseForOptions.flatMap { _ in
            smartBranchBase(in: repoRoot)
                ?? (try? resolvedDiffBranchBase(explicitBranchBaseRef, in: repoRoot))
        }
        var sessionPersisted = false
        // Invert repoFileURLsBySource ([DiffSource: [repoRoot: URL]]) into
        // [repoRoot: [DiffSource.slug: basename]] so the regenerate endpoint
        // can rebuild the source/repo switchers from the already-written sibling
        // pages. The same descriptor authorizes typed Rust sessions for every
        // source, even when no branch base exists.
        var repoSourceFiles: [String: [String: String]] = [:]
        for (source, fileURLsByRepo) in repoFileURLsBySource {
            for (repo, fileURL) in fileURLsByRepo {
                repoSourceFiles[repo, default: [:]][source.slug] = fileURL.lastPathComponent
            }
        }
        let session = DiffViewerBranchSession(
            token: mapper.token,
            groupID: groupID,
            repoRoot: repoRoot,
            allowedRepoRoots: repoCandidates.map(\.repoRoot),
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            titleOverride: titleOverride,
            workspaceId: selectedContext.workspaceId,
            surfaceId: selectedContext.surfaceId,
            repoSourceFiles: repoSourceFiles
        )
        do {
            try writeDiffViewerBranchSession(session, rootDirectory: directory)
            sessionPersisted = true
        } catch {
            if diffViewerUsesTypedSidecar(runtime: target.runtime) {
                throw error
            }
            // Legacy hosts can still render the selected page without a session,
            // but cannot advertise the branch picker.
            selectedBranchBase = nil
        }
        func branchPicker(forBase base: DiffBranchBase?, repoRoot pickerRepoRoot: String = repoRoot) -> [String: Any]? {
            guard sessionPersisted, let base else { return nil }
            return diffViewerBranchPickerPayload(
                base: base,
                repoRoot: pickerRepoRoot,
                groupID: groupID,
                origin: mapper.origin,
                token: mapper.token
            )
        }

        var deferredPages: [DiffViewerDeferredSourcePage] = []
        if shouldDeferSelectedSource {
            try writeDiffViewerStatusHTML(
                to: selectedFileURL,
                title: titleOverride ?? selectedSource.title,
                sourceLabel: "git \(selectedSource.slug)",
                message: diffViewerLoadingDiffMessage(selectedSource.menuLabel),
                emptyMessage: selectedSource.emptyMessage,
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
                branchPicker: selectedSource == .branch ? branchPicker(forBase: selectedBranchBase) : nil,
                sessionSource: diffSessionSourcePayload(source: selectedSource, context: selectedContext),
                capabilityToken: mapper.token,
                assets: sharedAssets,
                sharedPayload: sharedPayload,
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
                    branchPickerBase: selectedSource == .branch ? selectedBranchBase : nil,
                    allowsSourceFallback: true,
                    sourceFallbacks: sourceFallbacks
                )
            )
        }
        for source in DiffSource.allCases where source != selectedSource {
            if let url = fileURLs[source] {
                var pageContext = selectedContext
                if source == .branch {
                    // Use the smart-resolved base so this deferred Branch page
                    // renders its diff against the SAME ref its picker advertises
                    // (selectedBranchBase), not the legacy origin/HEAD fallback.
                    pageContext.branchBaseRef = selectedBranchBase?.ref ?? branchBaseForOptions
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
                    emptyMessage: source.emptyMessage,
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
                    branchPicker: source == .branch ? branchPicker(forBase: selectedBranchBase) : nil,
                    sessionSource: diffSessionSourcePayload(source: source, context: pageContext),
                    capabilityToken: mapper.token,
                    assets: sharedAssets,
                    sharedPayload: sharedPayload,
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
                        baseOptions: source == .branch ? baseOptions : [],
                        branchPickerBase: source == .branch ? selectedBranchBase : nil
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
                // Compute THIS repo's own smart base so a repo-switched Branch page
                // renders against (and surfaces a picker for) the cmuxBase/PR/
                // upstream smart base, mirroring the selected repo page. Without
                // this, the page fell back to the legacy origin/HEAD resolver and
                // `deferredDiffViewerBranchPicker` returned nil (no picker). The
                // base is resolved in `option.repoRoot`, and `smartBranchBase`
                // caches per repoRoot so each repo's `gh` lookup runs at most once.
                let repoSmartBase: DiffBranchBase?
                if source != .branch {
                    repoSmartBase = nil
                } else if let explicitBranchBaseRef {
                    // Rust validates the explicit ref when this repo is selected.
                    // Avoid probing every sibling repo while writing lazy shells.
                    repoSmartBase = DiffBranchBase(
                        ref: explicitBranchBaseRef,
                        reason: DiffBranchBaseReason.manual,
                        confidence: "high"
                    )
                } else {
                    repoSmartBase = smartBranchBase(in: option.repoRoot)
                }
                let repoBranchBaseRef: String?
                if source == .branch {
                    repoBranchBaseRef = repoSmartBase?.ref
                        ?? (try? resolvedGitBranchDiffBaseRef(explicitBranchBaseRef, in: option.repoRoot))
                } else {
                    repoBranchBaseRef = selectedContext.branchBaseRef
                }
                // Advertise the picker only when the session was persisted (the
                // refs/regenerate endpoints read it) AND a base resolved, matching
                // the selected/base-candidate pages. The session allow-lists every
                // repo candidate, so its endpoints authorize this repo too.
                let repoPickerBase: DiffBranchBase?
                if source == .branch, sessionPersisted, let resolvedRef = repoBranchBaseRef {
                    repoPickerBase = repoSmartBase?.ref == resolvedRef
                        ? repoSmartBase
                        : DiffBranchBase(ref: resolvedRef, reason: DiffBranchBaseReason.manual, confidence: "high")
                } else {
                    repoPickerBase = nil
                }
                let pageContext = DiffSourceContext(
                    workspaceId: selectedContext.workspaceId,
                    surfaceId: selectedContext.surfaceId,
                    sessionId: selectedContext.sessionId,
                    repoRoot: option.repoRoot,
                    branchBaseRef: source == .branch ? repoBranchBaseRef : selectedContext.branchBaseRef
                )
                try writeDiffViewerStatusHTML(
                    to: url,
                    title: option.label,
                    sourceLabel: "git \(source.slug)",
                    message: diffViewerLoadingDiffMessage(option.label),
                    emptyMessage: source.emptyMessage,
                    isError: false,
                    pollForReplacement: true,
                    layout: layout,
                    layoutSource: layoutSource,
                    appearance: appearance,
                    sourceOptions: sourceOptionsForRepo(selected: source, selectedRepoRoot: option.repoRoot),
                    repoOptions: repoOptionsForSource(source, selectedRepoRoot: option.repoRoot),
                    baseOptions: [],
                    repoRoot: option.repoRoot,
                    branchBaseRef: source == .branch ? repoBranchBaseRef : nil,
                    branchPicker: source == .branch ? branchPicker(forBase: repoPickerBase, repoRoot: option.repoRoot) : nil,
                    sessionSource: diffSessionSourcePayload(source: source, context: pageContext),
                    capabilityToken: mapper.token,
                    assets: sharedAssets,
                    sharedPayload: sharedPayload,
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
                        baseOptions: [],
                        branchPickerBase: repoPickerBase
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
            // nil when the session write failed, so the deferred branchPickerBase
            // is omitted and the regenerate/refs endpoints are never advertised.
            let optionBase = sessionPersisted
                ? DiffBranchBase(ref: option.ref, reason: DiffBranchBaseReason.manual, confidence: "high")
                : nil
            try writeDiffViewerStatusHTML(
                to: url,
                title: option.label,
                sourceLabel: "git \(DiffSource.branch.slug)",
                message: diffViewerLoadingDiffMessage(option.label),
                emptyMessage: DiffSource.branch.emptyMessage,
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
                branchPicker: branchPicker(forBase: optionBase),
                sessionSource: diffSessionSourcePayload(source: .branch, context: pageContext),
                capabilityToken: mapper.token,
                assets: sharedAssets,
                sharedPayload: sharedPayload,
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
                    ),
                    branchPickerBase: optionBase
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
                branchPicker: selectedSource == .branch ? branchPicker(forBase: selectedBranchBase) : nil,
                assets: sharedAssets,
                sharedPayload: sharedPayload,
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
                branchPicker: selectedSource == .branch ? branchPicker(forBase: selectedBranchBase) : nil,
                assets: sharedAssets,
                sharedPayload: sharedPayload,
                runtime: target.runtime
            )
        }
        let pageURLs = [selectedFileURL] + deferredPages.map(\.url)
        var allowedFiles = try diffViewerAllowedFiles(
            pageURLs: pageURLs,
            assets: sharedAssets,
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
                runtime: target.runtime,
                origin: mapper.origin,
                groupID: groupID,
                token: mapper.token
            )
        )
    }


    private func completeDeferredDiffViewer(_ viewer: DiffViewerWriteResult) throws -> DiffViewerWriteResult {
        do {
            if let completeDeferred = viewer.completeDeferred {
                return try completeDeferred()
            }
            if !diffViewerUsesTypedSidecar(runtime: viewer.deferredSourceSet?.runtime) {
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
            }
            return viewer
        } catch {
            throw diffViewerCommandError(error)
        }
    }

    private func completeDeferredDiffViewerSelectedSource(
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

    private func completeDeferredDiffViewerSources(
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

    /// Reassemble the `branchPicker` payload for a deferred branch page from its
    /// stored base plus the source set's origin/groupID, or nil when not a
    /// branch page or the set lacks an origin/group.
    private func deferredDiffViewerBranchPicker(
        page: DiffViewerDeferredSourcePage,
        sourceSet: DiffViewerDeferredSourceSet
    ) -> [String: Any]? {
        guard page.source == .branch,
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
            branchPicker: deferredDiffViewerBranchPicker(page: page, sourceSet: sourceSet),
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
            branchPicker: deferredDiffViewerBranchPicker(page: page, sourceSet: sourceSet),
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
            branchPicker: deferredDiffViewerBranchPicker(page: page, sourceSet: sourceSet),
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

    private func diffViewerErrorMessage(_ error: Error) -> String {
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

    // MARK: - Branch picker session persistence + payload

    private func diffViewerBranchSessionURL(groupID: String, rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(".branch-session-\(groupID).json", isDirectory: false)
    }

    func writeDiffViewerBranchSession(
        _ session: DiffViewerBranchSession,
        rootDirectory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = diffViewerBranchSessionURL(groupID: session.groupID, rootDirectory: rootDirectory)
        try encoder.encode(session).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readDiffViewerBranchSession(
        groupID: String,
        rootDirectory: URL
    ) throws -> DiffViewerBranchSession {
        let url = diffViewerBranchSessionURL(groupID: groupID, rootDirectory: rootDirectory)
        return try JSONDecoder().decode(DiffViewerBranchSession.self, from: Data(contentsOf: url))
    }

    private func diffViewerGroupIDIsValid(_ groupID: String) -> Bool {
        guard (1...64).contains(groupID.count) else { return false }
        return groupID.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
    }

    /// The `branchPicker` payload object (FROZEN CONTRACT). Present only for the
    /// branch source. URLs point at the same origin the page is served from so
    /// the picker works under both the local HTTP server and the in-app scheme.
    private func diffViewerBranchPickerPayload(
        base: DiffBranchBase,
        repoRoot: String,
        groupID: String,
        origin: URL,
        token: String
    ) -> [String: Any] {
        let aheadBehind = diffBranchAheadBehind(base: base.ref, in: repoRoot)
        // Thread the active base into the refs URL so reopening the picker fetches
        // refs with `selectedBaseRef == base.ref`. Without this, a manually-typed
        // or raw-SHA base (one that is not a smart suggestion) never re-appears as
        // the "manual" Suggested row, so the user cannot see what they are
        // comparing against without retyping it.
        let refsURL = diffViewerBranchRefsURL(
            origin: origin,
            repoRoot: repoRoot,
            token: token,
            base: base.ref
        )
        let regenerateTemplate = diffViewerBranchRegenerateURLTemplate(
            origin: origin,
            repoRoot: repoRoot,
            groupID: groupID,
            token: token
        )
        // The head side of the comparison: a branch diff shows what the current
        // branch + working tree contains that the base does not, so name the
        // current branch (or a short SHA when HEAD is detached) and let the UI
        // render it as `<headRef> -> <base>` so the comparison is never implicit.
        let headRef: String
        if let branch = gitCurrentBranchName(in: repoRoot), !branch.isEmpty {
            headRef = branch
        } else if let shortSHA = try? gitSingleLine(["rev-parse", "--short", "HEAD"], in: repoRoot) {
            headRef = "HEAD@\(shortSHA)"
        } else {
            headRef = "HEAD"
        }
        var picker: [String: Any] = [
            "repoRoot": repoRoot,
            "groupId": groupID,
            "capabilityToken": token,
            "headRef": headRef,
            "currentRef": base.ref,
            "currentReason": diffBranchBaseReasonLabel(base.reason),
            "confidence": base.confidence,
            "refsURL": refsURL,
            "regenerateURLTemplate": regenerateTemplate
        ]
        if let aheadBehind {
            picker["aheadBehind"] = ["ahead": aheadBehind.ahead, "behind": aheadBehind.behind]
        } else {
            picker["aheadBehind"] = NSNull()
        }
        return picker
    }

    /// Build a same-origin URL for a picker endpoint. For the HTTP server origin
    /// (`http://127.0.0.1:<port>`) this yields an absolute URL; for the in-app
    /// custom scheme (`cmux-diff-viewer://<token>`) it yields a scheme URL whose
    /// host carries the token, which the in-app handler mirrors.
    private func diffViewerBranchEndpointURL(
        origin: URL,
        path: String,
        queryItems: [URLQueryItem]
    ) -> String {
        var components = URLComponents()
        components.scheme = origin.scheme
        components.host = origin.host
        components.port = origin.port
        components.path = path
        components.queryItems = queryItems
        return components.url?.absoluteString ?? ""
    }

    /// `base` (the active comparison ref) is forwarded as a query item so both the
    /// HTTP refs route (`sendDiffViewerHTTPRefs`) and the custom-scheme refs route
    /// (`handleDiffViewerRefsRoute` -> `runDiffViewerRefsCommand`) pass it through
    /// to `diffBranchRefGroups(selectedBaseRef:)`, which surfaces it as the manual
    /// Suggested row. A nil/empty base is omitted (legacy behavior, no row).
    private func diffViewerBranchRefsURL(origin: URL, repoRoot: String, token: String, base: String?) -> String {
        var queryItems = [
            URLQueryItem(name: "repo", value: repoRoot),
            URLQueryItem(name: "token", value: token)
        ]
        if let base, !base.isEmpty {
            queryItems.append(URLQueryItem(name: "base", value: base))
        }
        return diffViewerBranchEndpointURL(
            origin: origin,
            path: "/__cmux_diff_viewer_refs",
            queryItems: queryItems
        )
    }

    /// Regenerate URL with a literal `{ref}` placeholder the frontend substitutes
    /// (URL-encoded). We assemble the encoded query then splice the unescaped
    /// placeholder in so the frontend owns the final encoding of the ref value.
    private func diffViewerBranchRegenerateURLTemplate(
        origin: URL,
        repoRoot: String,
        groupID: String,
        token: String
    ) -> String {
        let withSentinel = diffViewerBranchEndpointURL(
            origin: origin,
            path: "/__cmux_diff_viewer_branch",
            queryItems: [
                URLQueryItem(name: "group", value: groupID),
                URLQueryItem(name: "repo", value: repoRoot),
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "base", value: "__CMUX_REF__")
            ]
        )
        // Scope the replacement to the `base` query value. A bare global replace
        // of the sentinel would also rewrite an occurrence inside the `repo` path
        // (arbitrary user path), leaving `base=__CMUX_REF__` unfilled and breaking
        // regeneration. `base` is the last query item, so `base=__CMUX_REF__`
        // appears verbatim and uniquely.
        return withSentinel.replacingOccurrences(of: "base=__CMUX_REF__", with: "base={ref}")
    }

    /// `cmux __diff-viewer-branch --group <g> --repo <root> --base <ref>` ->
    /// regenerate the branch page into the secure dir and print the new viewer URL
    /// (custom-scheme form) on stdout. Used by the in-app custom-scheme handler to
    /// mirror the HTTP `/__cmux_diff_viewer_branch` route after an app restart,
    /// when the local HTTP server is gone. Validates repo + base.
    func runDiffViewerBranchRegenerateCommand(commandArgs: [String]) throws {
        var group: String?
        var repo: String?
        var base: String?
        var token: String?
        var index = 0
        while index < commandArgs.count {
            switch commandArgs[index] {
            case "--group":
                guard index + 1 < commandArgs.count else { throw CLIError(message: "__diff-viewer-branch --group requires a value") }
                group = commandArgs[index + 1]; index += 2
            case "--repo":
                guard index + 1 < commandArgs.count else { throw CLIError(message: "__diff-viewer-branch --repo requires a path") }
                repo = commandArgs[index + 1]; index += 2
            case "--base":
                guard index + 1 < commandArgs.count else { throw CLIError(message: "__diff-viewer-branch --base requires a ref") }
                base = commandArgs[index + 1]; index += 2
            case "--token":
                guard index + 1 < commandArgs.count else { throw CLIError(message: "__diff-viewer-branch --token requires a value") }
                token = commandArgs[index + 1]; index += 2
            default:
                throw CLIError(message: "Unexpected __diff-viewer-branch argument: \(commandArgs[index])")
            }
        }
        guard let group, diffViewerGroupIDIsValid(group),
              let repo, !repo.isEmpty,
              let base, !base.isEmpty else {
            throw CLIError(message: "__diff-viewer-branch requires --group, --repo, and --base")
        }
        let rootDirectory = try diffViewerDirectory()
        let session = try readDiffViewerBranchSession(groupID: group, rootDirectory: rootDirectory)
        // Authorize the repo against THIS group's session only, not the global
        // allow-list, so a request for one group cannot regenerate a page for a
        // repo allow-listed solely by some other active session.
        guard diffViewerSessionAllowsRepo(session, repoRoot: repo),
              gitRefExists(base, in: repo) else {
            throw CLIError(message: "Invalid diff viewer branch regenerate request")
        }
        // The request token must own this group's session, so one active token
        // cannot drive regeneration for another branch session whose group it
        // happens to know. No token (HTTP server origin path) keeps prior
        // group-only behavior.
        if let token, !token.isEmpty, session.token != token {
            throw CLIError(message: "Diff viewer token does not match the requested branch session")
        }
        // Reuse the secure-dir generation, but emit a custom-scheme viewer URL so
        // the restored in-app surface can serve it without the HTTP server.
        let viewerURL = try regenerateDiffViewerBranchPageForScheme(
            session: session,
            repoRoot: repo,
            base: base,
            rootDirectory: rootDirectory
        )
        cliWriteStdout(Data((viewerURL.absoluteString + "\n").utf8))
    }

    /// Rebuild the SOURCE and REPO switcher options for a regenerated branch
    /// pick page from the sibling pages recorded in the session. Without this the
    /// pick page would render with empty `sourceOptions`/`repoOptions` and the
    /// React `NavigationSelect` (which hides when <2 options) would drop both
    /// switchers, stranding the user on the branch source. Older session files
    /// (no `repoSourceFiles`) fall back to empty options, matching prior behavior.
    ///
    /// The `.branch` source URL is overridden to `pickPageURL` (the page being
    /// generated) so re-selecting "Branch" keeps the currently picked base.
    private func regeneratedDiffViewerSwitcherOptions(
        session: DiffViewerBranchSession,
        repoRoot: String,
        rootDirectory: URL,
        mapper: DiffViewerURLMapper,
        pickPageURL: URL
    ) -> (sourceOptions: [DiffViewerSourceOption], repoOptions: [DiffViewerSourceOption]) {
        guard !session.repoSourceFiles.isEmpty else { return ([], []) }

        // Source switcher: one URL per DiffSource that has a recorded sibling
        // page for this repo. Branch points at the new pick page.
        var sourceURLs: [DiffSource: URL] = [:]
        if let filesBySlug = session.repoSourceFiles[repoRoot] {
            for source in DiffSource.allCases {
                if source == .branch {
                    sourceURLs[.branch] = pickPageURL
                    continue
                }
                guard let fileName = filesBySlug[source.slug],
                      let url = try? mapper.viewerURL(
                          for: rootDirectory.appendingPathComponent(fileName, isDirectory: false)
                      ) else {
                    continue
                }
                sourceURLs[source] = url
            }
        }
        let sourceOptions = sourceURLs.isEmpty
            ? []
            : diffViewerSourceOptions(selected: .branch, urls: sourceURLs)

        // Repo switcher: one branch-page URL per allowed repo that has one.
        let candidates = session.allowedRepoRoots.map { repo in
            DiffViewerRepoOption(
                repoRoot: repo,
                label: gitDiffViewerRepoLabel(repo, selectedRepoRoot: repoRoot)
            )
        }
        var repoURLs: [String: URL] = [:]
        for repo in session.allowedRepoRoots {
            guard let fileName = session.repoSourceFiles[repo]?[DiffSource.branch.slug],
                  let url = try? mapper.viewerURL(
                      for: rootDirectory.appendingPathComponent(fileName, isDirectory: false)
                  ) else {
                continue
            }
            // For the selected repo, branch resolves to the new pick page so the
            // repo switcher and source switcher agree on "current".
            repoURLs[repo] = repo == repoRoot ? pickPageURL : url
        }
        let repoOptions = diffViewerRepoOptions(
            selectedRepoRoot: repoRoot,
            candidates: candidates,
            urls: repoURLs
        )

        return (sourceOptions, repoOptions)
    }

    /// Custom-scheme variant of `regenerateDiffViewerBranchPage`. The embedded
    /// `branchPicker` URLs use the custom scheme (host = token) so the picker
    /// continues to work against the in-app handler rather than a dead HTTP port.
    private func regenerateDiffViewerBranchPageForScheme(
        session: DiffViewerBranchSession,
        repoRoot: String,
        base: String,
        rootDirectory: URL
    ) throws -> URL {
        guard let origin = URL(string: "\(DiffViewerURLMapper.scheme)://\(session.token)") else {
            throw CLIError(message: "Failed to build diff viewer scheme origin")
        }
        let mapper = DiffViewerURLMapper(
            token: session.token,
            rootDirectory: rootDirectory,
            origin: origin
        )
        let baseSlug = diffViewerBranchBaseSlug(base)
        let fileURL = rootDirectory.appendingPathComponent(
            "diff-\(session.groupID)-pick-\(baseSlug).html",
            isDirectory: false
        )
        let viewerURL = try mapper.viewerURL(for: fileURL)

        var context = DiffSourceContext(
            workspaceId: session.workspaceId,
            surfaceId: session.surfaceId,
            repoRoot: repoRoot,
            branchBaseRef: base
        )
        context.branchBaseRef = try resolvedGitBranchDiffBaseRef(base, in: repoRoot)

        let resolvedBase = DiffBranchBase(ref: context.branchBaseRef ?? base, reason: DiffBranchBaseReason.manual, confidence: "high")
        let picker = diffViewerBranchPickerPayload(
            base: resolvedBase,
            repoRoot: repoRoot,
            groupID: session.groupID,
            origin: origin,
            token: session.token
        )

        let input = try readGitDiffInput(source: .branch, context: context)
        let runtime = diffViewerExecutableURL(for: nil)
        let switchers = regeneratedDiffViewerSwitcherOptions(
            session: session,
            repoRoot: repoRoot,
            rootDirectory: rootDirectory,
            mapper: mapper,
            pickPageURL: viewerURL
        )
        try writeDiffViewerHTML(
            to: fileURL,
            patch: input.patch,
            title: session.titleOverride ?? input.defaultTitle,
            sourceLabel: input.sourceLabel,
            externalURL: input.externalURL,
            remotePatchURL: input.remotePatchURL,
            layout: session.layout,
            layoutSource: session.layoutSource,
            appearance: session.appearance,
            sourceOptions: switchers.sourceOptions,
            repoOptions: switchers.repoOptions,
            baseOptions: [],
            repoRoot: repoRoot,
            branchBaseRef: context.branchBaseRef,
            branchPicker: picker,
            runtime: runtime
        )
        let assets = try ensureDiffViewerAssets(nextTo: fileURL, runtime: runtime)
        let newFiles = try diffViewerAllowedFiles(
            pageURLs: [fileURL],
            assets: assets,
            mapper: mapper
        )
        try appendDiffViewerHTTPManifestFiles(
            newFiles,
            token: session.token,
            rootDirectory: rootDirectory
        )
        return viewerURL
    }

    func gitDiffViewerRepoOptions(
        selectedRepoRoot: String,
        context: DiffSourceContext
    ) -> [DiffViewerRepoOption] {
        let selectedURL = URL(fileURLWithPath: selectedRepoRoot, isDirectory: true).standardizedFileURL
        var candidateURLs: [URL] = [selectedURL]
        let parentURL = selectedURL.deletingLastPathComponent()

        candidateURLs.append(contentsOf: agentTurnDiffBaselineRepoURLs(context: context))

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

    private func agentTurnDiffBaselineRepoURLs(context: DiffSourceContext) -> [URL] {
        guard let workspaceId = normalizedDiffSourceValue(context.workspaceId),
              let surfaceId = normalizedDiffSourceValue(context.surfaceId),
              let store = try? readAgentTurnDiffBaselineStore(
                path: CMUXAgentTurnDiffBaselineFile.path(env: ProcessInfo.processInfo.environment)
              ) else {
            return []
        }
        let sessionId = normalizedDiffSourceValue(context.sessionId)
        let matchingRecords = store.records
            .filter { record in
                diffScopeIdentifierEquals(record.workspaceId, workspaceId) &&
                    diffScopeIdentifierEquals(record.surfaceId, surfaceId) &&
                    (sessionId == nil || record.sessionId == sessionId)
            }
            .sorted { $0.capturedAt > $1.capturedAt }
        var seen: Set<String> = []
        var urls: [URL] = []
        for record in matchingRecords {
            let repoRoot = standardizedDiffSourcePath(record.repoRoot)
            guard seen.insert(repoRoot).inserted else { continue }
            urls.append(URL(fileURLWithPath: repoRoot, isDirectory: true).standardizedFileURL)
        }
        return urls
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

    func diffViewerDirectory() throws -> URL {
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

    private func diffViewerHTTPServerOrigin(rootDirectory: URL, runtime: URL? = nil) throws -> URL {
        let rootDirectory = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        try validateSecureDiffViewerDirectory(rootDirectory, repairPermissions: false)

        if let state = try? readDiffViewerHTTPServerState(rootDirectory: rootDirectory),
           state.rootPath == rootDirectory.path,
           state.protocolVersion == Self.diffViewerHTTPServerProtocolVersion,
           (1...65535).contains(state.port),
           diffViewerHTTPServerStateMatchesRuntimeExecutable(state, runtime: runtime),
           diffViewerHTTPServerIsReachable(port: state.port) {
            guard let url = URL(string: "http://127.0.0.1:\(state.port)") else {
                throw CLIError(message: "Failed to build diff viewer server URL")
            }
            return url
        }

        return try startDiffViewerHTTPServer(rootDirectory: rootDirectory, runtime: runtime)
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

    private func diffViewerHTTPServerStateMatchesRuntimeExecutable(_ state: DiffViewerHTTPServerState, runtime: URL?) -> Bool {
        guard state.pid > 0,
              let currentExecutablePath = diffViewerServerExecutableURL(for: runtime)?.path,
              let serverExecutablePath = diffViewerHTTPServerExecutablePath(pid: state.pid),
              serverExecutablePath == currentExecutablePath else {
            return false
        }

        guard let recordedExecutablePath = state.executablePath else {
            return true
        }
        return recordedExecutablePath == currentExecutablePath
    }

    private func diffViewerHTTPServerExecutablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let baseAddress = pointer.baseAddress else { return 0 }
            return proc_pidpath(pid, baseAddress, UInt32(pointer.count))
        }
        guard count > 0 else {
            return nil
        }

        let rawPath = String(cString: buffer)
        if let resolvedPath = realpath(rawPath, nil) {
            defer { free(resolvedPath) }
            return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL.path
        }
        return URL(fileURLWithPath: rawPath).standardizedFileURL.path
    }

    func readDiffViewerHTTPServerPort(from handle: FileHandle, process: Process) throws -> Int {
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

    func diffViewerHTTPServerIsReachable(port: Int) -> Bool {
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

    func writeDiffViewerHTTPManifest(
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
            DiffViewerHTTPServerState(
                port: port,
                pid: getpid(),
                rootPath: rootDirectory.path,
                protocolVersion: Self.diffViewerHTTPServerProtocolVersion,
                executablePath: resolvedExecutableURL()?.path
            ),
            rootDirectory: rootDirectory
        )
        cliWriteStdout(Data("\(port)\n".utf8))

        while true {
            guard let clientFD = try acceptCLISocketNoSIGPIPE(
                serverFD,
                acceptFailureMessage: "Diff viewer server accept failed: \(posixErrorMessage(errno))",
                noSIGPIPEFailureMessage: "Failed to disable SIGPIPE on diff viewer client socket: \(posixErrorMessage(errno))"
            ) else { continue }
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleDiffViewerHTTPConnection(
                    fileDescriptor: clientFD,
                    port: port,
                    manifestCache: manifestCache,
                    rootDirectory: rootDirectory
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
                if let file = files[requestPath] {
                    lock.unlock()
                    return file
                }
                lock.unlock()
                let refreshedFiles = try owner.loadDiffViewerHTTPManifestFiles(token: token, rootDirectory: rootDirectory)
                lock.lock()
                filesByToken[token] = refreshedFiles
                let file = refreshedFiles[requestPath]
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
        manifestCache: DiffViewerHTTPManifestCache,
        rootDirectory: URL
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

            if request.path == "/__cmux_diff_viewer_refs" {
                try sendDiffViewerHTTPRefs(
                    request: request,
                    fileDescriptor: fd,
                    rootDirectory: rootDirectory,
                    omitBody: request.method == "HEAD"
                )
                return
            }

            if request.path == "/__cmux_diff_viewer_branch" {
                try sendDiffViewerHTTPBranchRegenerate(
                    request: request,
                    fileDescriptor: fd,
                    port: port,
                    rootDirectory: rootDirectory,
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

    /// Whether `repoRoot` matches any persisted branch session's allow-list in
    /// the secure dir. Both sides are standardized so symlinks do not bypass it.
    /// Like `diffViewerRepoIsAllowed`, but additionally requires the matching
    /// session to belong to `token`. Used to bind a request's custom-scheme token
    /// to the session it is allowed to act on, so one active token cannot read
    /// refs for an unrelated branch session's repo.
    func diffViewerTokenAllowsRepo(_ token: String, repoRoot: String, rootDirectory: URL) -> Bool {
        guard diffViewerHTTPIsValidToken(token) else { return false }
        let normalized = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: rootDirectory.path
        ) else {
            return false
        }
        for entry in entries where entry.hasPrefix(".branch-session-") && entry.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: rootDirectory.appendingPathComponent(entry, isDirectory: false)),
                  let session = try? JSONDecoder().decode(DiffViewerBranchSession.self, from: data),
                  session.token == token else {
                continue
            }
            for allowed in session.allowedRepoRoots {
                let allowedNormalized = URL(fileURLWithPath: allowed, isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath().path
                if allowedNormalized == normalized {
                    return true
                }
            }
        }
        return false
    }

    /// Whether `repoRoot` is in the allow-list of the SPECIFIC `session` (not any
    /// other active session). The regenerate routes carry a `group`, so they must
    /// authorize against the requested group's session alone; otherwise a request
    /// for group A could regenerate a page for repo B merely because some other
    /// active session allow-lists B. Normalizes both sides exactly like
    /// `diffViewerRepoIsAllowed` (standardize + resolve symlinks).
    private func diffViewerSessionAllowsRepo(_ session: DiffViewerBranchSession, repoRoot: String) -> Bool {
        let normalized = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        for allowed in session.allowedRepoRoots {
            let allowedNormalized = URL(fileURLWithPath: allowed, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path
            if allowedNormalized == normalized {
                return true
            }
        }
        return false
    }

    func diffViewerRepoIsAllowed(_ repoRoot: String, rootDirectory: URL) -> Bool {
        let normalized = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: rootDirectory.path
        ) else {
            return false
        }
        for entry in entries where entry.hasPrefix(".branch-session-") && entry.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: rootDirectory.appendingPathComponent(entry, isDirectory: false)),
                  let session = try? JSONDecoder().decode(DiffViewerBranchSession.self, from: data) else {
                continue
            }
            for allowed in session.allowedRepoRoots {
                let allowedNormalized = URL(fileURLWithPath: allowed, isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath().path
                if allowedNormalized == normalized {
                    return true
                }
            }
        }
        return false
    }

    /// `GET /__cmux_diff_viewer_refs?repo=<root>&token=<t>` -> grouped refs JSON.
    /// Requires the session `token` (the same unguessable token the page is
    /// served under) and validates it owns a session that allow-lists `repo`, so
    /// a local process that only knows the port cannot enumerate refs.
    private func sendDiffViewerHTTPRefs(
        request: DiffViewerHTTPRequest,
        fileDescriptor fd: Int32,
        rootDirectory: URL,
        omitBody: Bool
    ) throws {
        let query = request.queryItems()
        guard let repoRoot = query["repo"], !repoRoot.isEmpty,
              let token = query["token"], !token.isEmpty,
              diffViewerTokenAllowsRepo(token, repoRoot: repoRoot, rootDirectory: rootDirectory) else {
            try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: omitBody)
            return
        }
        let selectedBase = query["base"]
        let data = cachedDiffBranchRefGroupsPayloadForHTTP(
            repoRoot: repoRoot,
            selectedBaseRef: selectedBase,
            rootDirectory: rootDirectory
        )
        try sendDiffViewerHTTPResponse(
            fileDescriptor: fd,
            status: 200,
            reason: "OK",
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data,
            omitBody: omitBody
        )
    }

    /// `GET /__cmux_diff_viewer_branch?group=<g>&repo=<root>&base=<ref>` ->
    /// validate repo + base, regenerate a single branch page for that base into
    /// the secure dir, 302-redirect to the new viewer URL. Bad base -> 404 page.
    private func sendDiffViewerHTTPBranchRegenerate(
        request: DiffViewerHTTPRequest,
        fileDescriptor fd: Int32,
        port: Int,
        rootDirectory: URL,
        omitBody: Bool
    ) throws {
        let query = request.queryItems()
        guard let groupID = query["group"], diffViewerGroupIDIsValid(groupID),
              let repoRoot = query["repo"], !repoRoot.isEmpty,
              let base = query["base"], !base.isEmpty,
              let token = query["token"], !token.isEmpty,
              let session = try? readDiffViewerBranchSession(groupID: groupID, rootDirectory: rootDirectory),
              // The request token must own THIS group's session (mirrors the
              // custom-scheme `runDiffViewerBranchRegenerateCommand` check), so a
              // process that only knows the port + group cannot drive regenerate.
              session.token == token,
              // Authorize the repo against THIS group's session only, not the
              // global allow-list, so a request for one group cannot regenerate a
              // page for a repo allow-listed solely by some other active session.
              diffViewerSessionAllowsRepo(session, repoRoot: repoRoot) else {
            try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: omitBody)
            return
        }

        // Validate the base resolves to a commit in this repo before regenerating.
        guard gitRefExists(base, in: repoRoot) else {
            try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: omitBody)
            return
        }

        do {
            let viewerURL = try regenerateDiffViewerBranchPage(
                session: session,
                repoRoot: repoRoot,
                base: base,
                rootDirectory: rootDirectory,
                port: port
            )
            try sendDiffViewerHTTPResponse(
                fileDescriptor: fd,
                status: 302,
                reason: "Found",
                headers: [
                    "Location": viewerURL.absoluteString,
                    "Content-Type": "text/plain; charset=utf-8"
                ],
                body: Data("302 Found\n".utf8),
                omitBody: omitBody
            )
        } catch {
            try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: omitBody)
        }
    }

    /// Regenerate one branch diff page for `base` using the persisted session,
    /// reusing the original token/groupID so the new page is keyed into the same
    /// secure dir and served by the same manifest. Appends the new page to the
    /// manifest and returns the viewer URL to redirect to.
    private func regenerateDiffViewerBranchPage(
        session: DiffViewerBranchSession,
        repoRoot: String,
        base: String,
        rootDirectory: URL,
        port: Int
    ) throws -> URL {
        guard let origin = URL(string: "http://127.0.0.1:\(port)") else {
            throw CLIError(message: "Failed to build diff viewer origin")
        }
        let mapper = DiffViewerURLMapper(
            token: session.token,
            rootDirectory: rootDirectory,
            origin: origin
        )
        // Stable per-(group, base) filename so repeated picks reuse one page.
        let baseSlug = diffViewerBranchBaseSlug(base)
        let fileURL = rootDirectory.appendingPathComponent(
            "diff-\(session.groupID)-pick-\(baseSlug).html",
            isDirectory: false
        )
        let viewerURL = try mapper.viewerURL(for: fileURL)

        var context = DiffSourceContext(
            workspaceId: session.workspaceId,
            surfaceId: session.surfaceId,
            repoRoot: repoRoot,
            branchBaseRef: base
        )
        context.branchBaseRef = try resolvedGitBranchDiffBaseRef(base, in: repoRoot)

        let resolvedBase = DiffBranchBase(ref: context.branchBaseRef ?? base, reason: DiffBranchBaseReason.manual, confidence: "high")
        let picker = diffViewerBranchPickerPayload(
            base: resolvedBase,
            repoRoot: repoRoot,
            groupID: session.groupID,
            origin: origin,
            token: session.token
        )

        let input = try readGitDiffInput(source: .branch, context: context)
        let runtime = diffViewerExecutableURL(for: nil)
        let switchers = regeneratedDiffViewerSwitcherOptions(
            session: session,
            repoRoot: repoRoot,
            rootDirectory: rootDirectory,
            mapper: mapper,
            pickPageURL: viewerURL
        )
        try writeDiffViewerHTML(
            to: fileURL,
            patch: input.patch,
            title: session.titleOverride ?? input.defaultTitle,
            sourceLabel: input.sourceLabel,
            externalURL: input.externalURL,
            remotePatchURL: input.remotePatchURL,
            layout: session.layout,
            layoutSource: session.layoutSource,
            appearance: session.appearance,
            sourceOptions: switchers.sourceOptions,
            repoOptions: switchers.repoOptions,
            baseOptions: [],
            repoRoot: repoRoot,
            branchBaseRef: context.branchBaseRef,
            branchPicker: picker,
            runtime: runtime
        )

        // Append the regenerated page + its assets to the manifest so the file
        // server and in-app scheme handler will serve it.
        let assets = try ensureDiffViewerAssets(nextTo: fileURL, runtime: runtime)
        let newFiles = try diffViewerAllowedFiles(
            pageURLs: [fileURL],
            assets: assets,
            mapper: mapper
        )
        try appendDiffViewerHTTPManifestFiles(
            newFiles,
            token: session.token,
            rootDirectory: rootDirectory
        )
        return viewerURL
    }

    private func diffViewerBranchBaseSlug(_ base: String) -> String {
        let mapped = base.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let readable = String(mapped).prefix(48)
        let readablePart = readable.isEmpty ? "base" : String(readable)
        // Distinct refs can map to the same readable slug ("feature/a" and
        // "feature-a", or any two refs sharing the first 48 mapped chars), which
        // would collide to one filename and let one base overwrite another's
        // generated page. Append a short stable hash of the ORIGINAL ref so
        // distinct refs always get distinct files while the same ref reuses one.
        var hasher = SHA256()
        hasher.update(data: Data(base.utf8))
        let hash = diffBranchHexEncoded(hasher.finalize()).prefix(12)
        return "\(readablePart)-\(hash)"
    }

    /// Merge new allowlist entries into a token's existing manifest, deduping by
    /// request path (existing entries win). Used by on-demand branch regeneration.
    private func appendDiffViewerHTTPManifestFiles(
        _ newFiles: [DiffViewerAllowedFile],
        token: String,
        rootDirectory: URL
    ) throws {
        guard diffViewerHTTPIsValidToken(token) else {
            throw CLIError(message: "Invalid diff viewer token")
        }
        let url = diffViewerHTTPManifestURL(token: token, rootDirectory: rootDirectory)

        // Branch regeneration runs on concurrent connection queues, so two
        // concurrent base selections can race this read-modify-write: the later
        // write would drop the earlier page from the manifest and 404 it.
        // Serialize the whole sequence under a per-manifest flock, matching the
        // flock pattern used by updateAgentTurnDiffBaselineStore.
        let lockPath = url.path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open diff viewer manifest lock: \(lockPath)")
        }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX) != 0 {
            throw CLIError(message: "Failed to lock diff viewer manifest: \(url.path)")
        }
        defer { _ = flock(fd, LOCK_UN) }

        var files: [DiffViewerAllowedFile] = []
        if let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(DiffViewerHTTPManifest.self, from: data),
           manifest.token == token {
            files = manifest.files
        }
        var seen = Set(files.map(\.requestPath))
        for file in newFiles where !seen.contains(file.requestPath) {
            seen.insert(file.requestPath)
            files.append(file)
        }
        guard !files.isEmpty, files.count <= 4096 else {
            throw CLIError(message: "Invalid diff viewer allowlist size")
        }
        try writeDiffViewerHTTPManifest(token: token, files: files, rootDirectory: rootDirectory)
    }

    private struct DiffViewerHTTPRequest {
        var method: String
        var path: String
        // Percent-encoded query string (without the leading "?"), preserved for
        // the branch picker endpoints. Empty for the file-serving routes, which
        // ignore it.
        var rawQuery: String

        func queryItems() -> [String: String] {
            guard !rawQuery.isEmpty else { return [:] }
            var components = URLComponents()
            components.percentEncodedQuery = rawQuery
            var result: [String: String] = [:]
            for item in components.queryItems ?? [] {
                if result[item.name] == nil {
                    result[item.name] = item.value ?? ""
                }
            }
            return result
        }
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
        var rawQuery = ""
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            guard let components = URLComponents(string: target) else {
                throw CLIError(message: "Invalid diff viewer request target")
            }
            rawQuery = components.percentEncodedQuery ?? ""
            target = components.percentEncodedPath
        } else if let queryIndex = target.firstIndex(of: "?") {
            // Preserve the query string for the branch picker endpoints; the
            // file-serving routes ignore it.
            rawQuery = String(target[target.index(after: queryIndex)...])
            target = String(target[..<queryIndex])
        }
        guard target.hasPrefix("/") else {
            throw CLIError(message: "Invalid diff viewer request path")
        }
        return DiffViewerHTTPRequest(method: method, path: target, rawQuery: rawQuery)
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
        if file.filePath.hasSuffix(".deflate") {
            headers["Content-Encoding"] = "deflate"
        }
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
            return path.hasSuffix(".mjs") || path.hasSuffix(".js")
        }
        if mimeType == "text/x-diff" {
            return path.hasSuffix(".patch")
        }
        return false
    }

    private func posixErrorMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    func diffViewerAllowedFiles(
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

    private func diffViewerAllowedFilesWithExtraPage(
        _ pageURL: URL,
        files: [DiffViewerAllowedFile],
        mapper: DiffViewerURLMapper
    ) throws -> [DiffViewerAllowedFile] {
        let extra = try mapper.allowedFile(fileURL: pageURL, mimeType: "text/html")
        var seen: Set<String> = []
        var merged: [DiffViewerAllowedFile] = []
        for file in [extra] + files where seen.insert(file.requestPath).inserted {
            merged.append(file)
        }
        return merged
    }

    private func remotePatchURLMap(pageURL: URL, remoteURL: URL?) -> [String: URL] {
        guard let remoteURL else { return [:] }
        return [pageURL.standardizedFileURL.path: remoteURL]
    }

    func diffViewerShortcutPayload() -> [String: Any] {
        Dictionary(
            uniqueKeysWithValues: diffViewerShortcuts().map { action, shortcut in
                (action.rawValue, shortcut.jsonObject)
            }
        )
    }

    private func diffViewerShortcuts() -> [DiffViewerShortcutAction: DiffViewerShortcut] {
        var shortcuts = Dictionary(
            uniqueKeysWithValues: DiffViewerShortcutAction.allCases.map { action in
                (action, action.defaultShortcut)
            }
        )
        var managedActions = Set<DiffViewerShortcutAction>()

        for path in diffViewerShortcutSettingsPaths() {
            guard let settings = diffViewerShortcutSettings(at: path) else { continue }
            for (action, shortcut) in settings where !managedActions.contains(action) {
                shortcuts[action] = shortcut
                managedActions.insert(action)
            }
        }

        let primaryPath = Self.absoluteDiffViewerSettingsPath(Self.primarySettingsDisplayPath)
        if let settings = diffViewerShortcutSettings(at: primaryPath) {
            for (action, shortcut) in settings {
                shortcuts[action] = shortcut
                managedActions.insert(action)
            }
        }

        return shortcuts
    }

    private func diffViewerShortcutSettingsPaths() -> [String] {
        [
            Self.legacySettingsDisplayPath,
            Self.fallbackSettingsDisplayPath,
        ].map(Self.absoluteDiffViewerSettingsPath)
    }

    private func diffViewerShortcutSettings(at path: String) -> [DiffViewerShortcutAction: DiffViewerShortcut]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty,
              let sanitized = try? JSONCParser.preprocess(data: data),
              let root = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any],
              let shortcutsSection = root["shortcuts"] as? [String: Any] else {
            return nil
        }

        var rawBindings = shortcutsSection["bindings"] as? [String: Any] ?? [:]
        for (key, rawValue) in shortcutsSection where key != "bindings" && key != "showModifierHoldHints" {
            rawBindings[key] = rawValue
        }

        var bindings: [DiffViewerShortcutAction: DiffViewerShortcut] = [:]
        for action in DiffViewerShortcutAction.allCases {
            guard let rawBinding = rawBindings[action.rawValue],
                  let shortcut = Self.parseDiffViewerShortcut(rawBinding) else {
                continue
            }
            bindings[action] = shortcut
        }
        return bindings
    }

    private static func parseDiffViewerShortcut(_ rawValue: Any) -> DiffViewerShortcut? {
        if rawValue is NSNull {
            return .unbound
        }
        if let rawString = rawValue as? String {
            return parseDiffViewerShortcut(strokes: [rawString])
        }
        if let rawStrings = rawValue as? [String] {
            return rawStrings.isEmpty ? .unbound : parseDiffViewerShortcut(strokes: rawStrings)
        }
        return nil
    }

    private static func parseDiffViewerShortcut(strokes: [String]) -> DiffViewerShortcut? {
        guard !strokes.isEmpty, strokes.count <= 2 else { return nil }
        if strokes.count == 1, isUnboundDiffViewerShortcutToken(strokes[0]) {
            return .unbound
        }
        let parsed = strokes.compactMap(parseDiffViewerShortcutStroke)
        guard parsed.count == strokes.count, let first = parsed.first else { return nil }
        return DiffViewerShortcut(
            first: first,
            second: parsed.count == 2 ? parsed[1] : nil
        )
    }

    private static func parseDiffViewerShortcutStroke(_ rawValue: String) -> DiffViewerShortcutStroke? {
        let rawParts = rawValue.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let parts = rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let lastRawPart = rawParts.last, !lastRawPart.isEmpty else { return nil }

        var command = false
        var shift = false
        var option = false
        var control = false
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command", "⌘":
                command = true
            case "shift", "⇧":
                shift = true
            case "opt", "option", "alt", "⌥":
                option = true
            case "ctrl", "control", "ctl", "⌃":
                control = true
            default:
                return nil
            }
        }

        guard let key = parseDiffViewerShortcutKeyToken(lastRawPart) else { return nil }
        return DiffViewerShortcutStroke(key: key, command: command, shift: shift, option: option, control: control)
    }

    private static func parseDiffViewerShortcutKeyToken(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return rawValue == " " ? "space" : nil
        }

        switch trimmed.lowercased() {
        case "space", "spacebar", "<space>":
            return "space"
        case "slash":
            return "/"
        case "period", "dot":
            return "."
        case "comma":
            return ","
        default:
            guard trimmed.count == 1 else { return nil }
            return trimmed.lowercased()
        }
    }

    private static func isUnboundDiffViewerShortcutToken(_ rawValue: String) -> Bool {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "none", "clear", "unbound", "disabled":
            return true
        default:
            return false
        }
    }

    private static func absoluteDiffViewerSettingsPath(_ rawPath: String) -> String {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let expanded: String
        if rawPath == "~" {
            expanded = homePath
        } else if rawPath.hasPrefix("~/") {
            expanded = (homePath as NSString).appendingPathComponent(String(rawPath.dropFirst(2)))
        } else {
            expanded = rawPath
        }
        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    func diffViewerPatchFileURL(for viewerURL: URL) -> URL {
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
        layoutSource: String,
        appearance: DiffViewerAppearance,
        sourceOptions: [DiffViewerSourceOption],
        repoOptions: [DiffViewerSourceOption] = [],
        baseOptions: [DiffViewerSourceOption] = [],
        repoRoot: String? = nil,
        branchBaseRef: String? = nil,
        branchPicker: [String: Any]? = nil
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
            layoutSource: layoutSource,
            appearance: appearance,
            sourceOptions: sourceOptions,
            repoOptions: repoOptions,
            baseOptions: baseOptions,
            repoRoot: repoRoot,
            branchBaseRef: branchBaseRef,
            branchPicker: branchPicker
        )
        return viewerURL
    }

    func writeDiffViewerStatusHTML(
        to viewerURL: URL,
        title: String,
        sourceLabel: String,
        message: String,
        emptyMessage: String? = nil,
        isError: Bool,
        pollForReplacement: Bool,
        layout: String,
        layoutSource: String,
        appearance: DiffViewerAppearance,
        sourceOptions: [DiffViewerSourceOption],
        repoOptions: [DiffViewerSourceOption] = [],
        baseOptions: [DiffViewerSourceOption] = [],
        repoRoot: String? = nil,
        branchBaseRef: String? = nil,
        branchPicker: [String: Any]? = nil,
        sessionSource: [String: Any]? = nil,
        capabilityToken: String? = nil,
        assets: DiffViewerAssets? = nil,
        sharedPayload: DiffViewerSharedPayload? = nil,
        runtime: URL? = nil
    ) throws {
        try writeDiffViewerHTML(
            to: viewerURL,
            patch: "",
            title: title,
            sourceLabel: sourceLabel,
            externalURL: nil,
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            sourceOptions: sourceOptions,
            repoOptions: repoOptions,
            baseOptions: baseOptions,
            repoRoot: repoRoot,
            branchBaseRef: branchBaseRef,
            branchPicker: branchPicker,
            sessionSource: sessionSource,
            capabilityToken: capabilityToken,
            assets: assets,
            sharedPayload: sharedPayload,
            emptyMessage: emptyMessage,
            statusMessage: message,
            statusIsError: isError,
            pollForReplacement: pollForReplacement,
            runtime: runtime
        )
    }

    private func writeDiffViewerRedirectHTML(
        to viewerURL: URL,
        title: String,
        targetURL: URL,
        appearance: DiffViewerAppearance,
        runtime: URL? = nil
    ) throws {
        try writeDiffViewerPatchSidecar("", for: viewerURL)
        _ = try ensureDiffViewerAssets(nextTo: viewerURL, runtime: runtime)
        let target = targetURL.absoluteString
        let targetLiteral = try jsonStringLiteral(target)
        let escapedTitle = htmlEscaped(title)
        let escapedTarget = htmlEscaped(target)
        let prepaintStyle = diffViewerPrepaintStyle(appearance: appearance)
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="refresh" content="0;url=\(escapedTarget)">
          <title>\(escapedTitle)</title>
          \(prepaintStyle)
        </head>
        <body data-cmux-diff-redirect="\(escapedTarget)">
          <script>
            window.location.replace(\(targetLiteral));
          </script>
        </body>
        </html>
        """
        try html.write(to: viewerURL, atomically: true, encoding: .utf8)
    }

    func writeDiffViewerHTML(
        to viewerURL: URL,
        patch: String,
        localPatchURL: URL? = nil,
        title: String,
        sourceLabel: String,
        externalURL: String?,
        remotePatchURL: URL? = nil,
        layout: String,
        layoutSource: String,
        appearance: DiffViewerAppearance,
        sourceOptions: [DiffViewerSourceOption],
        repoOptions: [DiffViewerSourceOption] = [],
        baseOptions: [DiffViewerSourceOption] = [],
        repoRoot: String? = nil,
        branchBaseRef: String? = nil,
        branchPicker: [String: Any]? = nil,
        sessionSource: [String: Any]? = nil,
        capabilityToken: String? = nil,
        assets preparedAssets: DiffViewerAssets? = nil,
        sharedPayload preparedSharedPayload: DiffViewerSharedPayload? = nil,
        emptyMessage: String? = nil,
        statusMessage: String? = nil,
        statusIsError: Bool = false,
        pollForReplacement: Bool = false,
        runtime: URL? = nil
    ) throws {
        if let localPatchURL {
            try FileManager.default.moveItem(at: localPatchURL, to: diffViewerPatchFileURL(for: viewerURL))
        } else if remotePatchURL == nil {
            try writeDiffViewerPatchSidecar(patch, for: viewerURL)
        }
        let sharedPayload = preparedSharedPayload ?? DiffViewerSharedPayload(
            labels: DiffViewerLabels.localized().jsonObject,
            shortcuts: diffViewerShortcutPayload(),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
        var payload: [String: Any] = [
            "patchURL": diffViewerPatchURLString(for: viewerURL),
            "title": title,
            "sourceLabel": sourceLabel,
            "layout": layout,
            "layoutSource": layoutSource,
            "appearance": appearance.jsonObject,
            "labels": sharedPayload.labels,
            "shortcuts": sharedPayload.shortcuts,
            "sourceOptions": sourceOptions.map(\.jsonObject),
            "repoOptions": repoOptions.map(\.jsonObject),
            "baseOptions": baseOptions.map(\.jsonObject),
            "generatedAt": sharedPayload.generatedAt
        ]
        // Browser-hosted builds can select Fetch or WebSocket with the same
        // generated protocol. The macOS app uses its reply-capable WebKit bridge,
        // which forwards one request over stdio to the Rust sidecar without a
        // listener or idle daemon.
        if diffViewerUsesTypedSidecar(runtime: runtime) {
            payload["transport"] = [
                "kind": "webKit",
                "endpoint": "cmuxDiff",
                "protocolVersion": 1,
            ]
        }
        if let statusMessage {
            payload["statusMessage"] = statusMessage
            payload["statusIsError"] = statusIsError
        }
        if let emptyMessage {
            payload["emptyMessage"] = emptyMessage
        }
        if pollForReplacement {
            payload["pendingReplacement"] = true
        }
        if let externalURL {
            payload["externalURL"] = externalURL
        }
        if let repoRoot {
            payload["repoRoot"] = repoRoot
        }
        if let branchBaseRef {
            payload["branchBaseRef"] = branchBaseRef
        }
        if let branchPicker {
            payload["branchPicker"] = branchPicker
        }
        if let sessionSource, let capabilityToken {
            payload["sessionSource"] = sessionSource
            payload["capabilityToken"] = capabilityToken
        }
        let assets = try preparedAssets ?? ensureDiffViewerAssets(nextTo: viewerURL, runtime: runtime)
        let config: [String: Any] = [
            "payload": payload,
            "assets": [
                "diffsModuleURL": assets.diffsModuleURL,
                "treesModuleURL": assets.treesModuleURL,
                "workerPoolModuleURL": assets.workerPoolModuleURL,
                "workerModuleURL": assets.workerModuleURL
            ]
        ]
        let configLiteral = try jsonScriptLiteral(config)
        let appModuleURL = htmlEscaped(assets.appModuleURL)
        let escapedTitle = htmlEscaped(title)
        let htmlLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        let pendingAttribute = pollForReplacement ? " data-cmux-diff-pending=\"true\"" : ""
        let prepaintStyle = diffViewerPrepaintStyle(appearance: appearance)
        let html = """
        <!doctype html>
        <html lang="\(htmlEscaped(htmlLanguage))"\(pendingAttribute)>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedTitle)</title>
          \(prepaintStyle)
        </head>
        <body>
          <script id="cmux-diff-viewer-config" type="application/json">\(configLiteral)</script>
          <div id="root"></div>
          <script type="module" src="\(appModuleURL)"></script>
        </body>
        </html>
        """
        try html.write(to: viewerURL, atomically: true, encoding: .utf8)
    }

    func diffViewerPrepaintStyle(appearance: DiffViewerAppearance) -> String {
        let lightForeground = diffViewerCSSColor(appearance.lightTheme.foreground)
        let darkForeground = diffViewerCSSColor(appearance.darkTheme.foreground)
        return """
        <style id="cmux-diff-viewer-prepaint">
          :root {
            color-scheme: light dark;
            background: transparent;
          }
          html,
          body,
          #root {
            min-height: 100%;
          }
          html,
          body {
            margin: 0;
            background: transparent;
            color: \(lightForeground);
          }
          @media (prefers-color-scheme: dark) {
            :root {
              background: transparent;
            }
            html,
            body {
              background: transparent;
              color: \(darkForeground);
            }
          }
        </style>
        """
    }

    private func diffViewerCSSColor(_ rawValue: String, opacity: Double = 1) -> String {
        guard let color = normalizedDiffViewerHexColor(rawValue) else {
            return rawValue
        }
        let clampedOpacity = min(1, max(0, opacity))
        guard clampedOpacity < 1,
              let rgb = diffViewerRGBColor(color) else {
            return color
        }
        let red = Int((rgb.red * 255).rounded())
        let green = Int((rgb.green * 255).rounded())
        let blue = Int((rgb.blue * 255).rounded())
        return "rgba(\(red), \(green), \(blue), \(diffViewerCSSNumber(clampedOpacity)))"
    }

    private func diffViewerCSSNumber(_ value: Double) -> String {
        let rounded = roundedDiffViewerMetric(value)
        if rounded.rounded(.towardZero) == rounded {
            return String(Int(rounded))
        }
        var text = String(rounded)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    func ensureDiffViewerAssets(nextTo viewerURL: URL, runtime: URL? = nil) throws -> DiffViewerAssets {
        let sourceDirectory = try diffViewerBundledAssetDirectory(runtime: runtime)
        let assetDirectoryName = "pierre-diffs-1.2.7-trees-1.0.0-beta.4"
        let targetDirectory = viewerURL.deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(assetDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let appAssets = try diffViewerBundledAppAssetDirectory(nextTo: sourceDirectory)
        let appAssetDirectoryName = appAssets.targetDirectoryName
        let targetAppDirectory = viewerURL.deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(appAssetDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: targetAppDirectory, withIntermediateDirectories: true)

        let assetPaths = try diffViewerBundledAssetRelativePaths(in: sourceDirectory)
        guard assetPaths.contains("diffs.mjs"),
              assetPaths.contains("trees.mjs"),
              assetPaths.contains("worker-pool/worker-pool.mjs"),
              assetPaths.contains("worker-pool/worker-portable.js") else {
            throw CLIError(message: "Bundled diff viewer entry assets not found")
        }
        let copiedAssetURLs = try assetPaths.map {
            try copyDiffViewerAsset(relativePath: $0, from: sourceDirectory, to: targetDirectory)
        }

        let appAssetPaths = try diffViewerBundledAssetRelativePaths(in: appAssets.sourceDirectory)
        guard appAssetPaths.contains("main.mjs") else {
            throw CLIError(message: "Bundled cmux diff viewer app entry asset not found")
        }
        let copiedAppAssetURLs = try appAssetPaths.map {
            try copyDiffViewerAsset(relativePath: $0, from: appAssets.sourceDirectory, to: targetAppDirectory)
        }

        return DiffViewerAssets(
            appModuleURL: "./assets/\(appAssetDirectoryName)/main.mjs",
            diffsModuleURL: "./assets/\(assetDirectoryName)/diffs.mjs",
            treesModuleURL: "./assets/\(assetDirectoryName)/trees.mjs",
            workerPoolModuleURL: "./assets/\(assetDirectoryName)/worker-pool/worker-pool.mjs",
            workerModuleURL: "./assets/\(assetDirectoryName)/worker-pool/worker-portable.js",
            files: copiedAssetURLs + copiedAppAssetURLs
        )
    }

    private func diffViewerBundledAppAssetDirectory(
        nextTo sourceDirectory: URL
    ) throws -> (sourceDirectory: URL, targetDirectoryName: String) {
        let sourceRoot = sourceDirectory.deletingLastPathComponent()
        let candidates: [(sourceName: String, targetName: String)] = [
            ("webviews-app", "cmux-webviews-app"),
            ("diff-viewer-app", "cmux-diff-viewer-app")
        ]
        for candidate in candidates {
            let appDirectory = sourceRoot
                .appendingPathComponent(candidate.sourceName, isDirectory: true)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: appDirectory.path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               (try? diffViewerBundledAssetFileURL(relativePath: "main.mjs", in: appDirectory)) != nil {
                // The shared /tmp asset cache is written by every running cmux
                // build (stable, nightly, each tagged dev app). Content-key the
                // directory so builds with different webview bundles coexist
                // instead of clobbering each other's chunks, which broke pages
                // whose per-token allowlist no longer matched the files on disk.
                let targetName = "\(candidate.targetName)-\(try diffViewerAppAssetContentKey(directory: appDirectory))"
                return (sourceDirectory: appDirectory, targetDirectoryName: targetName)
            }
        }
        throw CLIError(message: "Bundled cmux diff viewer app assets not found")
    }

    private func diffViewerAppAssetContentKey(directory: URL) throws -> String {
        var hasher = SHA256()
        for relativePath in try diffViewerBundledAssetRelativePaths(in: directory).sorted() {
            hasher.update(data: Data(relativePath.utf8))
            let fileURL = try diffViewerBundledAssetFileURL(relativePath: relativePath, in: directory)
            hasher.update(data: try Data(contentsOf: fileURL, options: .mappedIfSafe))
        }
        let digest = hasher.finalize()
        return String(diffBranchHexEncoded(digest).prefix(12))
    }

    private func copyDiffViewerAsset(relativePath: String, from sourceDirectory: URL, to targetDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        let sourceURL = try diffViewerBundledAssetFileURL(relativePath: relativePath, in: sourceDirectory)
        let targetRelativePath = sourceURL.path.hasSuffix(".deflate") ? relativePath + ".deflate" : relativePath
        let targetURL = targetDirectory.appendingPathComponent(targetRelativePath, isDirectory: false)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CLIError(message: "Bundled diff viewer asset not found: \(relativePath)")
        }

        let sourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if isCurrentDiffViewerAsset(targetURL: targetURL, sourceValues: sourceValues) {
            return targetURL
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
                return targetURL
            }
            throw error
        }
        return targetURL
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

    func htmlEscaped(_ raw: String) -> String {
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
        func typedSessionLeaseIsActive(token: String) -> Bool {
            let leaseURL = directory.appendingPathComponent(".session-lease-\(token).lock")
            let descriptor = Darwin.open(leaseURL.path, O_RDWR)
            guard descriptor >= 0 else { return false }
            defer { Darwin.close(descriptor) }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                _ = flock(descriptor, LOCK_UN)
                return false
            }
            return errno == EWOULDBLOCK
        }
        var activeTypedSessionTokens: Set<String> = []
        var activeTypedSessionFiles: Set<String> = []
        for manifestURL in entries {
            let name = manifestURL.lastPathComponent
            guard name.hasPrefix(".manifest-"), manifestURL.pathExtension == "json",
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = manifest["token"] as? String,
                  typedSessionLeaseIsActive(token: token),
                  let files = manifest["files"] as? [[String: Any]],
                  files.contains(where: { file in
                      guard file["remote_url"] == nil || file["remote_url"] is NSNull,
                            let path = file["file_path"] as? String else {
                          return false
                      }
                      let fileURL = URL(fileURLWithPath: path)
                      return fileURL.lastPathComponent.hasPrefix("diff-session-")
                          && fileURL.pathExtension == "patch"
                          && FileManager.default.fileExists(atPath: fileURL.path)
                  }) else {
                continue
            }
            activeTypedSessionTokens.insert(token)
            for file in files {
                guard file["remote_url"] == nil || file["remote_url"] is NSNull,
                      let path = file["file_path"] as? String else {
                    continue
                }
                activeTypedSessionFiles.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        }
        let sorted = entries.compactMap { url -> (url: URL, date: Date)? in
            guard url.pathExtension == "html",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in sorted.enumerated() where index >= 50 && now.timeIntervalSince(entry.date) > 24 * 60 * 60 {
            guard !activeTypedSessionFiles.contains(entry.url.standardizedFileURL.path) else {
                continue
            }
            try? FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: diffViewerPatchFileURL(for: entry.url))
        }

        for patchURL in entries where patchURL.pathExtension == "patch" {
            // Typed sidecar patches have independent manifest/index ownership.
            // The Rust cleanup path distinguishes active sessions from closed
            // deletion retries; the legacy HTML-sibling rule cannot.
            guard !patchURL.lastPathComponent.hasPrefix("diff-session-") else {
                continue
            }
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
            let token = manifestURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: ".manifest-", with: "")
            guard !activeTypedSessionTokens.contains(token) else {
                continue
            }
            guard let values = try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  now.timeIntervalSince(values.contentModificationDate ?? values.creationDate ?? .distantPast) > 24 * 60 * 60 else {
                continue
            }
            try? FileManager.default.removeItem(at: manifestURL)
        }

        // Branch-picker sidecars, abandoned atomic writes, and transient locks accumulate in this
        // shared per-uid dir, and the refs authorization path scans ALL
        // `.branch-session-*.json` on every request, so stale sessions also grow
        // request latency. Age-prune them on the SAME 24h staleness rule the diff
        // files above use: a `.branch-session-*.json` older than 24h backs no live
        // page (its HTML/patch/manifest siblings are already past the prune
        // threshold too), and refs caches/atomic writes are recomputable. Lock
        // files are removed only while this process holds their exclusive lock.
        for entry in entries {
            let name = entry.lastPathComponent
            let isBranchSession = name.hasPrefix(".branch-session-") && entry.pathExtension == "json"
            let isRefsCache = name.hasPrefix(".refs-cache-") && entry.pathExtension == "json"
            let isLock = entry.pathExtension == "lock"
            let isAtomicWrite = entry.pathExtension == "tmp"
                && (name.hasPrefix(".diff-session-temp-index-") || name.hasPrefix(".manifest-"))
            guard isBranchSession || isRefsCache || isLock || isAtomicWrite else {
                continue
            }
            if isBranchSession,
               let data = try? Data(contentsOf: entry),
               let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = session["token"] as? String,
               activeTypedSessionTokens.contains(token) {
                continue
            }
            guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  now.timeIntervalSince(values.contentModificationDate ?? values.creationDate ?? .distantPast) > 24 * 60 * 60 else {
                continue
            }
            if isLock {
                let descriptor = Darwin.open(entry.path, O_RDWR)
                guard descriptor >= 0 else { continue }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                    Darwin.close(descriptor)
                    continue
                }
                try? FileManager.default.removeItem(at: entry)
                _ = flock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            } else {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    func openSubcommandUsage() -> String {
        """
        Usage: cmux open <path-or-url>... [options]

        Open files, directories, or URLs in cmux.
        HTML files open in browser splits without focusing by default.
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
          --session <id>               Scope --last-turn to one agent session
          --window <id|ref|index>      Target window
          --cwd, --repo <path>          Git repository or worktree path for git sources
          --base <ref>                  Base ref for --branch (default: origin/HEAD or main)
          --focus <true|false>         Focus the diff browser split (default: false)
          --no-focus                   Do not focus the opened diff browser split
          --title <text>               Set the diff viewer title to the provided text
          --layout <split|unified>     Diff layout (default: unified; configurable via diffViewer.defaultLayout in cmux.json)
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
