import AppKit
import Foundation
import SwiftUI

nonisolated enum GitDiffReviewFileStatus: Equatable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case typeChanged
    case unknown(String)

    var label: String {
        switch self {
        case .modified:
            return String(localized: "codeReview.status.modified", defaultValue: "Modified")
        case .added:
            return String(localized: "codeReview.status.added", defaultValue: "Added")
        case .deleted:
            return String(localized: "codeReview.status.deleted", defaultValue: "Deleted")
        case .renamed:
            return String(localized: "codeReview.status.renamed", defaultValue: "Renamed")
        case .copied:
            return String(localized: "codeReview.status.copied", defaultValue: "Copied")
        case .untracked:
            return String(localized: "codeReview.status.untracked", defaultValue: "Untracked")
        case .typeChanged:
            return String(localized: "codeReview.status.typeChanged", defaultValue: "Type changed")
        case .unknown(let raw):
            return String.localizedStringWithFormat(
                String(localized: "codeReview.status.unknown", defaultValue: "Unknown (%@)"),
                raw
            )
        }
    }
}

nonisolated enum GitDiffReviewLineKind: Equatable, Sendable {
    case context
    case addition
    case deletion
    case note
}

nonisolated struct GitDiffReviewLine: Equatable, Sendable {
    let kind: GitDiffReviewLineKind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let content: String
}

nonisolated struct GitDiffReviewHunk: Equatable, Sendable {
    let header: String
    let oldStart: Int
    let newStart: Int
    let lines: [GitDiffReviewLine]
}

nonisolated struct GitDiffReviewFile: Identifiable, Equatable, Sendable {
    let path: String
    let oldPath: String?
    let status: GitDiffReviewFileStatus
    let additions: Int
    let deletions: Int
    let hunks: [GitDiffReviewHunk]

    var id: String {
        if let oldPath {
            return "\(oldPath)->\(path)"
        }
        return path
    }
}

nonisolated struct GitDiffReviewSnapshot: Equatable, Sendable {
    let repositoryRoot: String
    let branch: String
    let files: [GitDiffReviewFile]
    let loadedAt: Date

    var additions: Int {
        files.reduce(0) { $0 + $1.additions }
    }

    var deletions: Int {
        files.reduce(0) { $0 + $1.deletions }
    }
}

nonisolated enum GitDiffReviewLoadError: Error, Equatable, Sendable {
    case missingDirectory(String)
    case notGitRepository(String)
    case commandFailed(String)
    case cancelled

    var displayMessage: String {
        switch self {
        case .missingDirectory:
            return String(localized: "codeReview.error.notLocalDirectory", defaultValue: "Code Review needs a local workspace directory.")
        case .notGitRepository:
            return String(localized: "codeReview.error.notGitRepository", defaultValue: "This directory is not inside a Git repository.")
        case .commandFailed(let message):
            return message
        case .cancelled:
            return String(localized: "codeReview.error.cancelled", defaultValue: "Diff loading was cancelled.")
        }
    }
}

nonisolated enum GitDiffReviewPhase: Equatable, Sendable {
    case idle
    case loading(rootPath: String)
    case loaded(GitDiffReviewSnapshot)
    case failed(rootPath: String, error: GitDiffReviewLoadError)
}

nonisolated enum GitDiffReviewParser {
    private struct StatusEntry: Equatable {
        let status: GitDiffReviewFileStatus
        let oldPath: String?
    }

    static func parse(diffText: String, statusText: String) -> [GitDiffReviewFile] {
        let statusEntries = parseStatusEntries(statusText)
        var files: [GitDiffReviewFile] = []

        var currentPath: String?
        var currentOldPath: String?
        var currentStatus: GitDiffReviewFileStatus = .modified
        var currentHunks: [GitDiffReviewHunk] = []
        var currentHunkHeader: String?
        var currentHunkOldStart = 0
        var currentHunkNewStart = 0
        var currentLines: [GitDiffReviewLine] = []
        var oldLineNumber = 0
        var newLineNumber = 0
        var additions = 0
        var deletions = 0

        func flushHunk() {
            guard let header = currentHunkHeader else { return }
            currentHunks.append(
                GitDiffReviewHunk(
                    header: header,
                    oldStart: currentHunkOldStart,
                    newStart: currentHunkNewStart,
                    lines: currentLines
                )
            )
            currentHunkHeader = nil
            currentLines.removeAll(keepingCapacity: true)
        }

        func flushFile() {
            guard let path = currentPath else { return }
            flushHunk()
            let statusEntry = statusEntries[path]
            files.append(
                GitDiffReviewFile(
                    path: path,
                    oldPath: statusEntry?.oldPath ?? currentOldPath,
                    status: statusEntry?.status ?? currentStatus,
                    additions: additions,
                    deletions: deletions,
                    hunks: currentHunks
                )
            )
            currentPath = nil
            currentOldPath = nil
            currentStatus = .modified
            currentHunks.removeAll(keepingCapacity: true)
            currentLines.removeAll(keepingCapacity: true)
            currentHunkHeader = nil
            additions = 0
            deletions = 0
        }

        for rawLine in diffText.components(separatedBy: "\n") {
            let line = rawLine.removingTrailingCarriageReturn()

            if line.hasPrefix("diff --git ") {
                flushFile()
                let paths = parseDiffGitPaths(line)
                currentOldPath = paths.oldPath
                currentPath = paths.newPath
                currentStatus = statusEntries[paths.newPath]?.status ?? .modified
                continue
            }

            guard currentPath != nil else { continue }

            if line.hasPrefix("new file mode") {
                currentStatus = .added
                continue
            }
            if line.hasPrefix("deleted file mode") {
                currentStatus = .deleted
                continue
            }
            if line.hasPrefix("similarity index") {
                currentStatus = .renamed
                continue
            }
            if line.hasPrefix("rename from ") {
                currentOldPath = String(line.dropFirst("rename from ".count))
                currentStatus = .renamed
                continue
            }
            if line.hasPrefix("rename to ") {
                currentPath = String(line.dropFirst("rename to ".count))
                currentStatus = .renamed
                continue
            }
            if line.hasPrefix("@@ ") {
                flushHunk()
                let starts = parseHunkStarts(line)
                currentHunkHeader = line
                currentHunkOldStart = starts.oldStart
                currentHunkNewStart = starts.newStart
                oldLineNumber = starts.oldStart
                newLineNumber = starts.newStart
                continue
            }

            guard currentHunkHeader != nil else { continue }

            if line.hasPrefix("+") {
                currentLines.append(
                    GitDiffReviewLine(
                        kind: .addition,
                        oldLineNumber: nil,
                        newLineNumber: newLineNumber,
                        content: String(line.dropFirst())
                    )
                )
                newLineNumber += 1
                additions += 1
            } else if line.hasPrefix("-") {
                currentLines.append(
                    GitDiffReviewLine(
                        kind: .deletion,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: nil,
                        content: String(line.dropFirst())
                    )
                )
                oldLineNumber += 1
                deletions += 1
            } else if line.hasPrefix("\\") {
                currentLines.append(
                    GitDiffReviewLine(
                        kind: .note,
                        oldLineNumber: nil,
                        newLineNumber: nil,
                        content: line
                    )
                )
            } else {
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                currentLines.append(
                    GitDiffReviewLine(
                        kind: .context,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: newLineNumber,
                        content: content
                    )
                )
                oldLineNumber += 1
                newLineNumber += 1
            }
        }

        flushFile()

        let existingPaths = Set(files.map(\.path))
        let statusOnlyFiles = statusEntries
            .filter { !existingPaths.contains($0.key) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { path, entry in
                GitDiffReviewFile(
                    path: path,
                    oldPath: entry.oldPath,
                    status: entry.status,
                    additions: 0,
                    deletions: 0,
                    hunks: []
                )
            }
        return files + statusOnlyFiles
    }

    private static func parseStatusEntries(_ statusText: String) -> [String: StatusEntry] {
        var entries: [String: StatusEntry] = [:]
        let tokens = statusText.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            guard token.count >= 4 else {
                index += 1
                continue
            }

            let statusCode = String(token.prefix(2))
            let path = String(token.dropFirst(3))
            let status = statusFromPorcelain(statusCode)
            var oldPath: String?

            if status == .renamed || status == .copied {
                let nextIndex = index + 1
                if nextIndex < tokens.count {
                    oldPath = tokens[nextIndex]
                    index += 1
                }
            }

            entries[path] = StatusEntry(status: status, oldPath: oldPath)
            index += 1
        }

        return entries
    }

    private static func statusFromPorcelain(_ code: String) -> GitDiffReviewFileStatus {
        if code == "??" {
            return .untracked
        }
        if code.contains("R") {
            return .renamed
        }
        if code.contains("C") {
            return .copied
        }
        if code.contains("A") {
            return .added
        }
        if code.contains("D") {
            return .deleted
        }
        if code.contains("T") {
            return .typeChanged
        }
        if code.contains("M") {
            return .modified
        }
        return .unknown(code.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseDiffGitPaths(_ line: String) -> (oldPath: String?, newPath: String) {
        let body = String(line.dropFirst("diff --git ".count))
        guard let splitRange = body.range(of: " b/") else {
            return (nil, body)
        }

        var oldPath = String(body[..<splitRange.lowerBound])
        if oldPath.hasPrefix("a/") {
            oldPath = String(oldPath.dropFirst(2))
        }
        let newPath = String(body[splitRange.upperBound...])
        return (oldPath, newPath)
    }

    private static func parseHunkStarts(_ header: String) -> (oldStart: Int, newStart: Int) {
        let parts = header.split(separator: " ")
        guard parts.count >= 3 else { return (0, 0) }
        return (
            oldStart: parseRangeStart(String(parts[1])),
            newStart: parseRangeStart(String(parts[2]))
        )
    }

    private static func parseRangeStart(_ range: String) -> Int {
        var trimmed = range
        if trimmed.hasPrefix("-") || trimmed.hasPrefix("+") {
            trimmed.removeFirst()
        }
        let start = trimmed.split(separator: ",", maxSplits: 1).first.map(String.init) ?? trimmed
        return Int(start) ?? 0
    }
}

nonisolated enum GitDiffReviewLoader {
    static func load(rootPath: String) throws -> GitDiffReviewSnapshot {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GitDiffReviewLoadError.missingDirectory(rootPath)
        }

        let repositoryRoot = try runGit(["-C", rootPath, "rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryRoot.isEmpty else {
            throw GitDiffReviewLoadError.notGitRepository(rootPath)
        }

        let branch = gitBranchLabel(repositoryRoot: repositoryRoot)
        let statusText = try runGit(["-C", repositoryRoot, "status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let diffText = try runGit(["-C", repositoryRoot, "diff", "--no-ext-diff", "--no-color", "--find-renames", "HEAD", "--"])

        return GitDiffReviewSnapshot(
            repositoryRoot: repositoryRoot,
            branch: branch,
            files: GitDiffReviewParser.parse(diffText: diffText, statusText: statusText),
            loadedAt: Date()
        )
    }

    private static func gitBranchLabel(repositoryRoot: String) -> String {
        let branch = try? runGit(["-C", repositoryRoot, "branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch, !branch.isEmpty {
            return branch
        }

        let head = try? runGit(["-C", repositoryRoot, "rev-parse", "--short", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let head, !head.isEmpty {
            return head
        }

        return "HEAD"
    }

    private static func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, newValue in newValue }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw GitDiffReviewLoadError.commandFailed(error.localizedDescription)
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("not a git repository") {
                throw GitDiffReviewLoadError.notGitRepository(arguments.joined(separator: " "))
            }
            throw GitDiffReviewLoadError.commandFailed(
                message.isEmpty
                    ? String.localizedStringWithFormat(
                        String(localized: "codeReview.error.gitFailed", defaultValue: "git exited with status %d"),
                        process.terminationStatus
                    )
                    : message
            )
        }

        return output
    }
}

@MainActor
final class GitDiffReviewStore: ObservableObject {
    @Published private(set) var phase: GitDiffReviewPhase = .idle

    private var rootPath: String?
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    deinit {
        loadTask?.cancel()
    }

    func setRootPath(_ nextRootPath: String?) {
        let normalized = Self.normalizedRootPath(nextRootPath)
        guard normalized != rootPath else {
            if case .idle = phase, normalized != nil {
                reload()
            }
            return
        }

        rootPath = normalized
        generation &+= 1
        loadTask?.cancel()

        guard normalized != nil else {
            phase = .idle
            return
        }

        reload()
    }

    func reload() {
        guard let rootPath else {
            phase = .idle
            return
        }

        generation &+= 1
        let currentGeneration = generation
        phase = .loading(rootPath: rootPath)
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try GitDiffReviewLoader.load(rootPath: rootPath)
                }.value
                try Task.checkCancellation()
                self?.completeLoad(snapshot, generation: currentGeneration)
            } catch is CancellationError {
                self?.completeFailure(.cancelled, rootPath: rootPath, generation: currentGeneration)
            } catch let error as GitDiffReviewLoadError {
                self?.completeFailure(error, rootPath: rootPath, generation: currentGeneration)
            } catch {
                self?.completeFailure(.commandFailed(error.localizedDescription), rootPath: rootPath, generation: currentGeneration)
            }
        }
    }

    private func completeLoad(_ snapshot: GitDiffReviewSnapshot, generation completedGeneration: Int) {
        guard completedGeneration == generation else { return }
        phase = .loaded(snapshot)
    }

    private func completeFailure(_ error: GitDiffReviewLoadError, rootPath: String, generation completedGeneration: Int) {
        guard completedGeneration == generation else { return }
        if case .cancelled = error {
            return
        }
        phase = .failed(rootPath: rootPath, error: error)
    }

    private static func normalizedRootPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CodeReviewPanelView: View {
    @ObservedObject var store: GitDiffReviewStore
    let rootPath: String?

    private var normalizedRootPath: String? {
        let trimmed = rootPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            store.setRootPath(normalizedRootPath)
        }
        .onChange(of: normalizedRootPath) { _, newValue in
            store.setRootPath(newValue)
        }
        .accessibilityIdentifier("CodeReviewPanel")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "codeReview.title", defaultValue: "Code Review"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(normalizedRootPath == nil || isLoading)
            .safeHelp(String(localized: "codeReview.refresh", defaultValue: "Refresh"))
            .accessibilityLabel(String(localized: "codeReview.refresh", defaultValue: "Refresh"))
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private var headerSubtitle: String {
        switch store.phase {
        case .loaded(let snapshot):
            return String.localizedStringWithFormat(
                String(localized: "codeReview.header.loaded", defaultValue: "%@ - %@"),
                snapshot.branch,
                snapshot.repositoryRoot
            )
        case .loading(let rootPath), .failed(let rootPath, _):
            return rootPath
        case .idle:
            return normalizedRootPath ?? String(localized: "codeReview.noWorkspace.title", defaultValue: "No workspace directory")
        }
    }

    private var isLoading: Bool {
        if case .loading = store.phase {
            return true
        }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            CodeReviewEmptyStateView(
                systemImage: "folder.badge.questionmark",
                title: String(localized: "codeReview.noWorkspace.title", defaultValue: "No workspace directory"),
                message: String(localized: "codeReview.noWorkspace.message", defaultValue: "Open a local workspace directory to review changes.")
            )
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "codeReview.loading", defaultValue: "Loading diff..."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(_, let error):
            CodeReviewEmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: String(localized: "codeReview.error.title", defaultValue: "Unable to load diff"),
                message: error.displayMessage
            )
        case .loaded(let snapshot):
            if snapshot.files.isEmpty {
                CodeReviewEmptyStateView(
                    systemImage: "checkmark.circle",
                    title: String(localized: "codeReview.noChanges.title", defaultValue: "No changes"),
                    message: String(localized: "codeReview.noChanges.message", defaultValue: "This working tree matches HEAD.")
                )
            } else {
                CodeReviewSnapshotView(snapshot: snapshot)
            }
        }
    }
}

private struct CodeReviewSnapshotView: View {
    let snapshot: GitDiffReviewSnapshot

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                CodeReviewSummaryView(snapshot: snapshot)
                ForEach(snapshot.files) { file in
                    CodeReviewFileSection(file: file)
                }
            }
            .padding(10)
        }
    }
}

private struct CodeReviewSummaryView: View {
    let snapshot: GitDiffReviewSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Text(
                String.localizedStringWithFormat(
                    String(localized: "codeReview.summary.files", defaultValue: "%lld files"),
                    snapshot.files.count
                )
            )
            .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 0)

            Text(
                String.localizedStringWithFormat(
                    String(localized: "codeReview.summary.churn", defaultValue: "+%lld -%lld"),
                    snapshot.additions,
                    snapshot.deletions
                )
            )
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct CodeReviewFileSection: View {
    let file: GitDiffReviewFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if file.hunks.isEmpty {
                Text(emptyDiffMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(file.hunks.indices, id: \.self) { hunkIndex in
                    CodeReviewHunkView(hunk: file.hunks[hunkIndex])
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: file.path)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Text(file.status.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(
                String.localizedStringWithFormat(
                    String(localized: "codeReview.file.churn", defaultValue: "+%lld -%lld"),
                    file.additions,
                    file.deletions
                )
            )
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    }

    private var emptyDiffMessage: String {
        if file.status == .untracked {
            return String(localized: "codeReview.untracked.message", defaultValue: "Untracked file; diff content is not available yet.")
        }
        return String(localized: "codeReview.noTextDiff.message", defaultValue: "No textual diff is available for this file.")
    }
}

private struct CodeReviewHunkView: View {
    let hunk: GitDiffReviewHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: hunk.header)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

            ForEach(hunk.lines.indices, id: \.self) { lineIndex in
                CodeReviewDiffLineView(line: hunk.lines[lineIndex])
            }
        }
    }
}

private struct CodeReviewDiffLineView: View {
    let line: GitDiffReviewLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            lineNumberText(line.oldLineNumber)
            lineNumberText(line.newLineNumber)
            Text(verbatim: linePrefix)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(prefixColor)
                .frame(width: 16, alignment: .center)
            Text(verbatim: line.content.isEmpty ? " " : line.content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .lineLimit(nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 8)
        .background(backgroundColor)
    }

    private func lineNumberText(_ number: Int?) -> some View {
        Text(verbatim: number.map { String($0) } ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 38, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var linePrefix: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .note: return "\\"
        case .context: return " "
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .addition: return Color(nsColor: .systemGreen)
        case .deletion: return Color(nsColor: .systemRed)
        case .note: return Color(nsColor: .secondaryLabelColor)
        case .context: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var foregroundColor: Color {
        switch line.kind {
        case .addition: return Color(nsColor: .systemGreen)
        case .deletion: return Color(nsColor: .systemRed)
        case .note: return Color(nsColor: .secondaryLabelColor)
        case .context: return .primary
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .addition:
            return Color(nsColor: .systemGreen).opacity(0.10)
        case .deletion:
            return Color(nsColor: .systemRed).opacity(0.10)
        case .note:
            return Color(nsColor: .controlBackgroundColor).opacity(0.50)
        case .context:
            return Color.clear
        }
    }
}

private struct CodeReviewEmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension String {
    func removingTrailingCarriageReturn() -> String {
        guard hasSuffix("\r") else { return self }
        return String(dropLast())
    }
}
