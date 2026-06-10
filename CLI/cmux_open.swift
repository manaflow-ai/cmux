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

enum CMUXAgentTurnUntrackedSnapshotLimits {
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
    enum DiffViewerLimits {
        static let repoOptions = 4
        static let branchBaseOptions = 4
    }

    struct OpenArguments {
        var workspace: String?
        var window: String?
        var surface: String?
        var pane: String?
        var focus: String?
        var noFocus = false
        var targets: [String] = []
    }

    enum OpenTarget {
        case directory(String)
        case file(String)
        case url(String)
    }

    struct DiffArguments {
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

    struct DiffInput {
        var patch: String
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

    struct DiffViewerDeferredCompletion {
        var input: DiffInput
        var fileURL: URL
        var viewerURL: URL
        var completedPageURLs: Set<URL>
    }

    struct DiffViewerRepoOption {
        var repoRoot: String
        var label: String
    }

    struct DiffViewerBranchBaseOption {
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

    struct DiffViewerAssets {
        var appModuleURL: String
        var diffsModuleURL: String
        var treesModuleURL: String
        var workerPoolModuleURL: String
        var workerModuleURL: String
        var files: [URL]
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

    struct DiffViewerHTTPManifest: Codable {
        var token: String
        var files: [DiffViewerAllowedFile]
    }

    struct DiffViewerHTTPServerState: Codable {
        var port: Int
        var pid: Int32
        var rootPath: String
        var protocolVersion: String?
        var executablePath: String?
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
                "bars": CMUXDiffViewerLocalization.string("diffViewer.bars", defaultValue: "Bars"),
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

    enum DiffViewerShortcutAction: String, CaseIterable {
        case scrollDown = "diffViewerScrollDown"
        case scrollUp = "diffViewerScrollUp"
        case scrollToBottom = "diffViewerScrollToBottom"
        case scrollToTop = "diffViewerScrollToTop"
        case openFileSearch = "diffViewerOpenFileSearch"

        var defaultShortcut: DiffViewerShortcut {
            switch self {
            case .scrollDown:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "j"))
            case .scrollUp:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "k"))
            case .scrollToBottom:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "g", shift: true))
            case .scrollToTop:
                return DiffViewerShortcut(
                    first: DiffViewerShortcutStroke(key: "g"),
                    second: DiffViewerShortcutStroke(key: "g")
                )
            case .openFileSearch:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "/"))
            }
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

    enum DiffViewerColorScheme {
        case light
        case dark
    }

    struct DiffViewerAppearance {
        var backgroundOpacity: Double
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

    struct DiffViewerTheme {
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

}
