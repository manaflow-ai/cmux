import Foundation
import Combine
import Darwin

struct GitChangedFile: Identifiable, Hashable {
    let id: String
    let path: String
    let status: GitFileStatus
    let staged: Bool
    let oldPath: String?

    init(id: String, path: String, status: GitFileStatus, staged: Bool, oldPath: String? = nil) {
        self.id = id
        self.path = path
        self.status = status
        self.staged = staged
        self.oldPath = oldPath
    }
}

enum GitFileStatus: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
    case conflicted = "U"

    var symbolName: String {
        switch self {
        case .modified:
            return "pencil.line"
        case .added:
            return "plus.circle.fill"
        case .deleted:
            return "minus.circle.fill"
        case .renamed:
            return "arrow.left.arrow.right"
        case .copied:
            return "doc.on.doc.fill"
        case .untracked:
            return "questionmark.circle.fill"
        case .conflicted:
            return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
final class GitDiffPanel: Panel, ObservableObject {
    private struct GitStatusSnapshot {
        let isRepository: Bool
        let gitDirectoryPath: String?
        let branchName: String?
        let changedFiles: [GitChangedFile]
    }

    private struct GitDiffSnapshot {
        let html: String
        let isTooLarge: Bool
    }

    let id: UUID
    let panelType: PanelType = .gitDiff
    private(set) var workspaceId: UUID

    @Published private(set) var changedFiles: [GitChangedFile] = []
    @Published private(set) var selectedFile: GitChangedFile?
    @Published private(set) var diffHTML: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var displayTitle: String = "Git Changes"
    @Published private(set) var focusFlashToken: Int = 0
    @Published private(set) var isGitRepository: Bool = true
    @Published private(set) var branchName: String?

    var displayIcon: String? { "arrow.triangle.branch" }

    private nonisolated(unsafe) var gitDirectoryWatchSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var gitIndexWatchSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var refsHeadsWatchSource: DispatchSourceFileSystemObject?
    private var gitDirectoryFileDescriptor: Int32 = -1
    private var gitIndexFileDescriptor: Int32 = -1
    private var refsHeadsFileDescriptor: Int32 = -1
    private var refreshDebounceWorkItem: DispatchWorkItem?
    private var gitDirectoryPath: String?
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(label: "com.cmux.git-diff-watch", qos: .utility)

    /// Whether the panel is currently visible in the UI. When false,
    /// file-system events are deferred until the panel becomes visible
    /// again, avoiding wasted git process spawns and WebView renders.
    /// Starts as false so the first setVisible(true) triggers a refresh.
    private var isVisibleInPanel: Bool = false

    /// Set when a refresh was skipped because the panel was hidden.
    /// Checked when the panel becomes visible again. Starts true so the
    /// first setVisible(true) triggers the initial git status load.
    private var needsRefreshOnVisible: Bool = true

    /// Tracks the last set of changed file IDs so we can skip redundant
    /// diff reloads when nothing actually changed.
    private var lastChangedFileIDs: Set<String> = []

    /// Simple diff output cache keyed on file ID. Cleared on each
    /// status refresh since the underlying content may have changed.
    private nonisolated(unsafe) var diffCache: [String: String] = [:]
    private let diffCacheLock = NSLock()

    /// Whether a status refresh is already in flight on the watch queue.
    /// Prevents queueing duplicate refreshes while one is running.
    private var isRefreshInFlight: Bool = false

    let workingDirectory: String

    private static let diffByteLimit = 500_000
    private nonisolated static let diffByteLimitValue = 500_000

    // Debounce delay increased from 0.2s to 1.5s to prevent process
    // spawn storms when coding agents are rapidly saving files.
    private static let refreshDebounceDelay: TimeInterval = 1.5

    init(workspaceId: UUID, workingDirectory: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.workingDirectory = workingDirectory
    }

    func focus() {
        // Read-only panel; no explicit first responder to manage.
    }

    func unfocus() {
        // No-op for read-only panel.
    }

    func close() {
        isClosed = true
        refreshDebounceWorkItem?.cancel()
        stopGitWatchers()
    }

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    /// Called by the view layer when visibility changes (e.g. tab switch).
    func setVisible(_ visible: Bool) {
        let wasHidden = !isVisibleInPanel
        isVisibleInPanel = visible
        if visible && wasHidden && needsRefreshOnVisible {
            needsRefreshOnVisible = false
            refreshGitStatus()
        }
    }

    func refreshGitStatus() {
        guard !isClosed else { return }

        // Skip refresh if the panel is not visible; mark for later.
        guard isVisibleInPanel else {
            needsRefreshOnVisible = true
            return
        }

        // Don't queue a second refresh while one is already running.
        guard !isRefreshInFlight else {
            needsRefreshOnVisible = true
            return
        }

        isLoading = true
        isRefreshInFlight = true
        let directory = workingDirectory
        watchQueue.async { [weak self] in
            let snapshot = Self.loadGitStatusSnapshot(directory: directory)
            DispatchQueue.main.async {
                guard let self, !self.isClosed else { return }
                self.isRefreshInFlight = false
                self.applyGitStatusSnapshot(snapshot)

                // If another refresh was requested while we were working,
                // kick off a new one now.
                if self.needsRefreshOnVisible && self.isVisibleInPanel {
                    self.needsRefreshOnVisible = false
                    self.refreshGitStatus()
                }
            }
        }
    }

    func selectFile(_ file: GitChangedFile?) {
        selectedFile = file
        guard let file else {
            diffHTML = ""
            return
        }

        // Check the diff cache first.
        diffCacheLock.lock()
        let cachedDiff = diffCache[file.id]
        diffCacheLock.unlock()

        if let cachedDiff {
            let css = Diff2HtmlResources.css
            let js = Diff2HtmlResources.javaScript
            // Build HTML on the background queue to keep main thread free.
            watchQueue.async { [weak self] in
                let snapshot = Self.buildDiffSnapshot(diffOutput: cachedDiff, css: css, js: js)
                DispatchQueue.main.async {
                    guard let self, !self.isClosed else { return }
                    guard self.selectedFile == file else { return }
                    self.diffHTML = snapshot.html
                    self.isLoading = false
                }
            }
            return
        }

        isLoading = true
        let directory = workingDirectory
        let css = Diff2HtmlResources.css
        let js = Diff2HtmlResources.javaScript
        watchQueue.async { [weak self] in
            let diffOutput = Self.loadDiffOutput(directory: directory, file: file)

            // Store in cache.
            guard let self else { return }
            self.diffCacheLock.lock()
            self.diffCache[file.id] = diffOutput
            self.diffCacheLock.unlock()

            let snapshot = Self.buildDiffSnapshot(diffOutput: diffOutput, css: css, js: js)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isClosed else { return }
                guard self.selectedFile == file else { return }
                self.diffHTML = snapshot.html
                self.isLoading = false
            }
        }
    }

    private func applyGitStatusSnapshot(_ snapshot: GitStatusSnapshot) {
        isGitRepository = snapshot.isRepository
        branchName = snapshot.branchName

        // Invalidate the diff cache on every status refresh since the
        // underlying file content may have changed.
        diffCacheLock.lock()
        diffCache.removeAll()
        diffCacheLock.unlock()

        // Check if the file list actually changed before updating.
        let newIDs = Set(snapshot.changedFiles.map(\.id))
        let filesChanged = newIDs != lastChangedFileIDs
        lastChangedFileIDs = newIDs

        if filesChanged {
            changedFiles = snapshot.changedFiles
        }

        updateWatchedPaths(gitDirectoryPath: snapshot.gitDirectoryPath)

        guard snapshot.isRepository else {
            selectedFile = nil
            diffHTML = ""
            isLoading = false
            return
        }

        if snapshot.changedFiles.isEmpty {
            selectedFile = nil
            diffHTML = ""
            isLoading = false
            return
        }

        let currentSelection = selectedFile
        if let currentSelection,
           snapshot.changedFiles.contains(currentSelection) {
            // Only reload the diff if the file list actually changed
            // (meaning something was modified). If the list is identical,
            // the currently displayed diff is still valid.
            if filesChanged {
                selectFile(currentSelection)
            } else {
                isLoading = false
            }
        } else {
            selectFile(snapshot.changedFiles.first)
        }
    }

    private func updateWatchedPaths(gitDirectoryPath nextGitDirectoryPath: String?) {
        guard gitDirectoryPath != nextGitDirectoryPath else { return }
        stopGitWatchers()
        gitDirectoryPath = nextGitDirectoryPath
        guard let nextGitDirectoryPath else { return }
        startGitWatcher(path: nextGitDirectoryPath, kind: .gitDirectory)
        startGitWatcher(path: (nextGitDirectoryPath as NSString).appendingPathComponent("index"), kind: .index)
        startGitWatcher(path: (nextGitDirectoryPath as NSString).appendingPathComponent("refs/heads"), kind: .refsHeads)
    }

    private enum WatcherKind {
        case gitDirectory
        case index
        case refsHeads
    }

    private func startGitWatcher(path: String, kind: WatcherKind) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    guard !self.isClosed else { return }
                    self.updateWatchedPaths(gitDirectoryPath: nil)
                }
            }
            self.scheduleDebouncedRefresh()
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()

        switch kind {
        case .gitDirectory:
            gitDirectoryFileDescriptor = fd
            gitDirectoryWatchSource = source
        case .index:
            gitIndexFileDescriptor = fd
            gitIndexWatchSource = source
        case .refsHeads:
            refsHeadsFileDescriptor = fd
            refsHeadsWatchSource = source
        }
    }

    private func scheduleDebouncedRefresh() {
        refreshDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.refreshGitStatus()
            }
        }
        refreshDebounceWorkItem = workItem
        watchQueue.asyncAfter(deadline: .now() + Self.refreshDebounceDelay, execute: workItem)
    }

    private func stopGitWatchers() {
        gitDirectoryWatchSource?.cancel()
        gitDirectoryWatchSource = nil
        gitIndexWatchSource?.cancel()
        gitIndexWatchSource = nil
        refsHeadsWatchSource?.cancel()
        refsHeadsWatchSource = nil
        gitDirectoryFileDescriptor = -1
        gitIndexFileDescriptor = -1
        refsHeadsFileDescriptor = -1
    }

    deinit {
        gitDirectoryWatchSource?.cancel()
        gitIndexWatchSource?.cancel()
        refsHeadsWatchSource?.cancel()
    }

    private nonisolated static func loadGitStatusSnapshot(directory: String) -> GitStatusSnapshot {
        guard let gitDirectoryPath = resolveGitDirectoryPath(directory: directory) else {
            return GitStatusSnapshot(
                isRepository: false,
                gitDirectoryPath: nil,
                branchName: nil,
                changedFiles: []
            )
        }

        let branchName = normalizedBranchName(
            runGitCommand(directory: directory, arguments: ["branch", "--show-current"])
        )
        let output = runGitCommand(
            directory: directory,
            arguments: ["status", "--porcelain=v1", "--untracked-files=all"]
        ) ?? ""

        return GitStatusSnapshot(
            isRepository: true,
            gitDirectoryPath: gitDirectoryPath,
            branchName: branchName,
            changedFiles: parseChangedFiles(from: output)
        )
    }

    /// Build a GitDiffSnapshot from raw diff output. Separated from
    /// loadDiffOutput so cached diff strings can skip the git process.
    private nonisolated static func buildDiffSnapshot(diffOutput: String, css: String, js: String) -> GitDiffSnapshot {
        // Binary files produce "Binary files ... differ" instead of a
        // unified diff. Detect this early and show a clean empty state.
        if diffOutput.contains("Binary files") && diffOutput.contains("differ") {
            let title = String(localized: "gitDiff.binaryFile.title", defaultValue: "Binary file")
            let message = String(
                localized: "gitDiff.binaryFile.message",
                defaultValue: "Binary files cannot be displayed as a text diff."
            )
            let html = emptyStateHTML(
                icon: "doc.fill",
                title: title,
                message: message
            )
            return GitDiffSnapshot(html: html, isTooLarge: false)
        }

        let byteCount = diffOutput.lengthOfBytes(using: .utf8)
        if byteCount > Self.diffByteLimitValue {
            let title = String(localized: "gitDiff.diffTooLarge.title", defaultValue: "Diff too large")
            let message = String(
                localized: "gitDiff.diffTooLarge.message",
                defaultValue: "This diff is larger than the panel limit. Open it in the terminal for the full output."
            )
            let html = emptyStateHTML(
                icon: "doc.text.magnifyingglass",
                title: title,
                message: message
            )
            return GitDiffSnapshot(html: html, isTooLarge: true)
        }
        return GitDiffSnapshot(html: diffHTMLTemplate(diffOutput: diffOutput, css: css, js: js), isTooLarge: false)
    }

    private nonisolated static func resolveGitDirectoryPath(directory: String) -> String? {
        guard let rawGitDirectory = runGitCommand(directory: directory, arguments: ["rev-parse", "--git-dir"]) else {
            return nil
        }
        let trimmed = rawGitDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        return URL(fileURLWithPath: directory)
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .path
    }

    private nonisolated static func loadDiffOutput(directory: String, file: GitChangedFile) -> String {
        if file.status == .conflicted {
            // Show the working tree version with conflict markers against HEAD.
            return runGitCommand(
                directory: directory,
                arguments: ["diff", "--", file.path]
            ) ?? ""
        }

        if file.status == .untracked {
            // git diff --no-index exits with 1 when files differ (always,
            // since we're comparing /dev/null to a real file). That's the
            // expected case, so we accept non-zero exit codes here.
            return runGitCommand(
                directory: directory,
                arguments: ["diff", "--no-index", "--", "/dev/null", file.path],
                allowNonZero: true
            ) ?? ""
        }

        var arguments = ["diff"]
        if file.staged {
            arguments.append("--cached")
        }
        // Enable rename detection and pass both old and new paths for
        // renames so git shows the actual delta instead of full delete+add.
        if file.status == .renamed, let oldPath = file.oldPath {
            arguments.append("-M")
            arguments.append(contentsOf: ["--", oldPath, file.path])
        } else {
            arguments.append(contentsOf: ["--", file.path])
        }
        return runGitCommand(directory: directory, arguments: arguments) ?? ""
    }

    private nonisolated static func parseChangedFiles(from output: String) -> [GitChangedFile] {
        var files: [GitChangedFile] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.count >= 3 else { continue }

            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            let pathStart = line.index(line.startIndex, offsetBy: 3)
            let rawPath = String(line[pathStart...])
            let resolvedPath = normalizePorcelainPath(rawPath)

            // For renames/copies, extract the old path from "old -> new".
            let renameOldPath: String?
            if let arrowRange = rawPath.range(of: " -> ", options: .backwards) {
                renameOldPath = String(rawPath[rawPath.startIndex..<arrowRange.lowerBound])
            } else {
                renameOldPath = nil
            }

            // Merge conflicts: UU, AA, DD, AU, UA, DU, UD.
            // Any line where either column is "U", or both are "A"/"D"
            // during a merge, indicates a conflict. Show once as unstaged.
            let isConflict = x == "U" || y == "U"
                || (x == "A" && y == "A")
                || (x == "D" && y == "D")
            if isConflict {
                files.append(
                    GitChangedFile(
                        id: "unstaged:\(resolvedPath)",
                        path: resolvedPath,
                        status: .conflicted,
                        staged: false
                    )
                )
                continue
            }

            // Untracked (??) and ignored (!!) entries are not staged;
            // show them only once in the unstaged list.
            if x == "?" || x == "!" {
                if let status = mapStatus(character: x) {
                    files.append(
                        GitChangedFile(
                            id: "unstaged:\(resolvedPath)",
                            path: resolvedPath,
                            status: status,
                            staged: false
                        )
                    )
                }
                continue
            }

            if x != " ", let status = mapStatus(character: x) {
                files.append(
                    GitChangedFile(
                        id: "staged:\(resolvedPath)",
                        path: resolvedPath,
                        status: status,
                        staged: true,
                        oldPath: renameOldPath
                    )
                )
            }

            if y != " ", let status = mapStatus(character: y) {
                files.append(
                    GitChangedFile(
                        id: "unstaged:\(resolvedPath)",
                        path: resolvedPath,
                        status: status,
                        staged: false,
                        oldPath: renameOldPath
                    )
                )
            }
        }

        return files
    }

    private nonisolated static func normalizePorcelainPath(_ rawPath: String) -> String {
        if let arrowRange = rawPath.range(of: " -> ", options: .backwards) {
            return String(rawPath[arrowRange.upperBound...])
        }
        return rawPath
    }

    private nonisolated static func mapStatus(character: Character) -> GitFileStatus? {
        switch character {
        case "M":
            return .modified
        case "A":
            return .added
        case "D":
            return .deleted
        case "R":
            return .renamed
        case "C":
            return .copied
        case "?":
            return .untracked
        case "U":
            return .conflicted
        default:
            return nil
        }
    }

    private nonisolated static func diffHTMLTemplate(diffOutput: String, css: String, js: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>\(css)</style>
          <style>
            :root {
              color-scheme: light dark;
            }
            body {
              margin: 0;
              padding: 8px;
              background: #ffffff;
              color: #1e1e1e;
              font-family: -apple-system, BlinkMacSystemFont, "SF Mono", Menlo, monospace;
              font-size: 12px;
            }
            @media (prefers-color-scheme: dark) {
              body {
                background: #1e1e1e;
                color: #d4d4d4;
              }
              .d2h-wrapper { background: #1e1e1e; }
              .d2h-file-header { background: #2d2d2d; border-color: #3c3c3c; color: #e0e0e0; }
              .d2h-file-wrapper { border-color: #3c3c3c; }
              .d2h-diff-table { background: #1e1e1e; color: #d4d4d4; }
              .d2h-code-line, .d2h-code-side-line { background: #1e1e1e; }
              .d2h-code-line-ctn { color: #d4d4d4; }
              /* Deletions: visible red tint with left accent */
              .d2h-del { background-color: #3b2020; border-color: #4a2a2a; border-left: 3px solid #c74e4e; }
              .d2h-del .d2h-code-line-ctn { color: #e0c8c8; }
              /* Additions: visible green tint with left accent */
              .d2h-ins { background-color: #1a3020; border-color: #254028; border-left: 3px solid #4ec74e; }
              .d2h-ins .d2h-code-line-ctn { color: #c8e0c8; }
              /* Inline word-level highlights: stronger than line wash */
              .d2h-file-diff .d2h-del.d2h-change { background-color: #4a2525; }
              .d2h-file-diff .d2h-ins.d2h-change { background-color: #253a25; }
              .d2h-del .d2h-code-line-ctn del { background-color: #6b3540; color: #f5c8c8; text-decoration: none; border-radius: 2px; }
              .d2h-ins .d2h-code-line-ctn ins { background-color: #2a5530; color: #c8f5c8; text-decoration: none; border-radius: 2px; }
              .d2h-info { background: #252526; color: #858585; border-color: #3c3c3c; }
              .d2h-code-linenumber { background: #252526; color: #6e6e6e; border-color: #333; }
              .d2h-del .d2h-code-linenumber { background: #261e1e; color: #8a6060; }
              .d2h-ins .d2h-code-linenumber { background: #1e261e; color: #608a60; }
              .d2h-emptyplaceholder, .d2h-code-side-emptyplaceholder { background: #252526; border-color: #333; }
              .d2h-tag { background: #333; color: #b0b0b0; border-radius: 3px; }
              .d2h-file-name { color: #e0e0e0; }
            }
          </style>
        </head>
        <body>
          <div id="diff"></div>
          <script>\(js)</script>
          <script>
            const diffString = \(javaScriptStringLiteral(diffOutput));
            document.getElementById("diff").innerHTML = Diff2Html.html(diffString, {
              drawFileList: false,
              outputFormat: "line-by-line",
              matching: "lines"
            });
          </script>
        </body>
        </html>
        """
    }

    nonisolated static func emptyStateHTML(icon: String, title: String, message: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root {
              color-scheme: light dark;
            }
            body {
              margin: 0;
              display: flex;
              align-items: center;
              justify-content: center;
              min-height: 100vh;
              background: #ffffff;
              color: #1e1e1e;
              font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            }
            @media (prefers-color-scheme: dark) {
              body {
                background: #1e1e1e;
                color: #d4d4d4;
              }
            }
            .wrap {
              max-width: 420px;
              padding: 24px;
              text-align: center;
            }
            .icon {
              font-size: 32px;
              margin-bottom: 12px;
            }
            .title {
              font-size: 18px;
              font-weight: 600;
              margin-bottom: 8px;
            }
            .message {
              font-size: 13px;
              opacity: 0.78;
              line-height: 1.4;
            }
          </style>
        </head>
        <body>
          <div class="wrap">
            <div class="icon">\(htmlEscaped(icon))</div>
            <div class="title">\(htmlEscaped(title))</div>
            <div class="message">\(htmlEscaped(message))</div>
          </div>
        </body>
        </html>
        """
    }

    private nonisolated static func javaScriptStringLiteral(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    private nonisolated static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Run a git command and return its stdout.
    /// - Parameter allowNonZero: When `true`, return stdout even if the
    ///   process exits with a non-zero status. `git diff --no-index` exits
    ///   with 1 when the inputs differ, which is the normal/expected case.
    private nonisolated static func runGitCommand(
        directory: String,
        arguments: [String],
        allowNonZero: Bool = false
    ) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !allowNonZero, process.terminationStatus != 0 {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func normalizedBranchName(_ branch: String?) -> String? {
        let trimmed = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
