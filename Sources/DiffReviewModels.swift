import Foundation

enum DiffReviewLineKind: Equatable, Sendable {
    case context
    case addition
    case deletion
    case metadata
}

struct DiffReviewLine: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: DiffReviewLineKind
    let marker: String
    let text: String
}

enum DiffReviewFileStatus: String, Equatable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case binary
}

struct DiffReviewHunk: Identifiable, Equatable, Sendable {
    let id: String
    let header: String
    let oldStart: Int
    let oldLength: Int
    let newStart: Int
    let newLength: Int
    let sectionHeading: String?
    let lines: [DiffReviewLine]
    let patch: String
    let addedLineCount: Int
    let deletedLineCount: Int
}

struct DiffReviewFile: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let oldPath: String?
    let status: DiffReviewFileStatus
    let hunks: [DiffReviewHunk]
    let addedLineCount: Int
    let deletedLineCount: Int
}

enum DiffReviewTarget: Equatable, Identifiable, Sendable {
    case workingTree
    case branch(String)

    static let workingTreeID = "working-tree"

    var id: String {
        switch self {
        case .workingTree:
            return Self.workingTreeID
        case .branch(let branchName):
            return "branch:\(branchName)"
        }
    }

    var branchName: String? {
        guard case .branch(let branchName) = self else { return nil }
        return branchName
    }

    var allowsHunkRevert: Bool {
        switch self {
        case .workingTree:
            return true
        case .branch:
            return false
        }
    }

    static func from(id: String, branches: [String]) -> DiffReviewTarget {
        if id == Self.workingTreeID {
            return .workingTree
        }
        if id.hasPrefix("branch:") {
            let branchName = String(id.dropFirst("branch:".count))
            if branches.contains(branchName) {
                return .branch(branchName)
            }
        }
        return .workingTree
    }
}

struct DiffReviewSnapshot: Equatable, Sendable {
    let repositoryRoot: String
    let currentBranch: String?
    let branches: [String]
    let selectedTarget: DiffReviewTarget
    let files: [DiffReviewFile]
    let generatedAt: Date

    var targets: [DiffReviewTarget] {
        [.workingTree] + branches.map(DiffReviewTarget.branch)
    }

    var totalAddedLineCount: Int {
        files.reduce(0) { $0 + $1.addedLineCount }
    }

    var totalDeletedLineCount: Int {
        files.reduce(0) { $0 + $1.deletedLineCount }
    }
}

enum DiffReviewLoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

enum DiffReviewPatchParser {
    static func parse(_ diffOutput: String, untrackedPaths: Set<String> = []) -> [DiffReviewFile] {
        guard !diffOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var files: [DiffReviewFile] = []
        var currentFile: FileAccumulator?

        for rawLine in diffOutput.components(separatedBy: "\n") {
            guard !rawLine.isEmpty else { continue }
            if rawLine.hasPrefix("diff --git ") {
                if let file = currentFile?.build(untrackedPaths: untrackedPaths) {
                    files.append(file)
                }
                currentFile = FileAccumulator(diffHeader: rawLine)
                continue
            }

            currentFile?.append(rawLine)
        }

        if let file = currentFile?.build(untrackedPaths: untrackedPaths) {
            files.append(file)
        }

        return files
    }

    private struct FileAccumulator {
        private let diffHeader: String
        private var fileHeaderLines: [String]
        private var hunkAccumulators: [HunkAccumulator] = []
        private var currentHunk: HunkAccumulator?

        init(diffHeader: String) {
            self.diffHeader = diffHeader
            self.fileHeaderLines = [diffHeader]
        }

        mutating func append(_ line: String) {
            if line.hasPrefix("@@ ") {
                flushCurrentHunk()
                currentHunk = HunkAccumulator(header: line)
                return
            }

            if currentHunk != nil {
                currentHunk?.append(line)
            } else {
                fileHeaderLines.append(line)
            }
        }

        mutating func build(untrackedPaths: Set<String>) -> DiffReviewFile? {
            flushCurrentHunk()
            guard let pathInfo = pathInfo() else { return nil }

            let status = fileStatus(
                path: pathInfo.path,
                untrackedPaths: untrackedPaths
            )
            let hunkValues = hunkAccumulators.enumerated().map { index, accumulator in
                accumulator.build(
                    id: "\(pathInfo.path):\(index)",
                    fileHeaderLines: fileHeaderLines
                )
            }
            let added = hunkValues.reduce(0) { $0 + $1.addedLineCount }
            let deleted = hunkValues.reduce(0) { $0 + $1.deletedLineCount }

            return DiffReviewFile(
                id: pathInfo.path,
                path: pathInfo.path,
                oldPath: pathInfo.oldPath,
                status: hunkValues.isEmpty && isBinaryChange ? .binary : status,
                hunks: hunkValues,
                addedLineCount: added,
                deletedLineCount: deleted
            )
        }

        private mutating func flushCurrentHunk() {
            guard let hunk = currentHunk else { return }
            hunkAccumulators.append(hunk)
            currentHunk = nil
        }

        private var isBinaryChange: Bool {
            fileHeaderLines.contains { $0.hasPrefix("Binary files ") || $0.hasPrefix("GIT binary patch") }
        }

        private func fileStatus(
            path: String,
            untrackedPaths: Set<String>
        ) -> DiffReviewFileStatus {
            if untrackedPaths.contains(path) {
                return .untracked
            }
            if fileHeaderLines.contains(where: { $0.hasPrefix("rename from ") || $0.hasPrefix("rename to ") }) {
                return .renamed
            }
            if fileHeaderLines.contains(where: { $0.hasPrefix("copy from ") || $0.hasPrefix("copy to ") }) {
                return .copied
            }
            if fileHeaderLines.contains(where: { $0.hasPrefix("new file mode ") }) {
                return .added
            }
            if fileHeaderLines.contains(where: { $0.hasPrefix("deleted file mode ") }) {
                return .deleted
            }
            if fileHeaderLines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "--- /dev/null" }) {
                return .added
            }
            if fileHeaderLines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "+++ /dev/null" }) {
                return .deleted
            }
            return .modified
        }

        private func pathInfo() -> (path: String, oldPath: String?)? {
            let oldPath = normalizedDiffPath(
                fileHeaderLines.first(where: { $0.hasPrefix("--- ") })?.dropFirst(4)
            )
            let newPath = normalizedDiffPath(
                fileHeaderLines.first(where: { $0.hasPrefix("+++ ") })?.dropFirst(4)
            )
            let renameTo = fileHeaderLines.first(where: { $0.hasPrefix("rename to ") }).map {
                String($0.dropFirst("rename to ".count))
            }
            let renameFrom = fileHeaderLines.first(where: { $0.hasPrefix("rename from ") }).map {
                String($0.dropFirst("rename from ".count))
            }
            let headerPath = pathFromDiffHeader()

            let path = renameTo ?? newPath ?? oldPath ?? headerPath
            guard let path, !path.isEmpty else { return nil }
            let previousPath = renameFrom ?? oldPath
            return (path, previousPath == path ? nil : previousPath)
        }

        private func pathFromDiffHeader() -> String? {
            let payload = String(diffHeader.dropFirst("diff --git ".count))
            let parts = payload.split(separator: " ", maxSplits: 1).map(String.init)
            guard let last = parts.last else { return nil }
            return normalizedDiffPath(last)
        }

        private func normalizedDiffPath<S: StringProtocol>(_ rawPath: S?) -> String? {
            guard let rawPath else { return nil }
            var path = String(rawPath).trimmingCharacters(in: .whitespacesAndNewlines)
            if path == "/dev/null" {
                return nil
            }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
                path.removeFirst()
                path.removeLast()
            }
            if path.hasPrefix("a/") || path.hasPrefix("b/") {
                path = String(path.dropFirst(2))
            }
            return path
        }
    }

    private struct HunkAccumulator {
        let header: String
        private var rawLines: [String] = []

        init(header: String) {
            self.header = header
        }

        mutating func append(_ line: String) {
            rawLines.append(line)
        }

        func build(id: String, fileHeaderLines: [String]) -> DiffReviewHunk {
            let range = hunkRange(header)
            let lines = rawLines.enumerated().map { index, rawLine in
                DiffReviewLine(
                    id: index,
                    kind: lineKind(rawLine),
                    marker: lineMarker(rawLine),
                    text: lineText(rawLine)
                )
            }
            let added = lines.filter { $0.kind == .addition }.count
            let deleted = lines.filter { $0.kind == .deletion }.count
            let patchLines = fileHeaderLines + [header] + rawLines

            return DiffReviewHunk(
                id: id,
                header: header,
                oldStart: range.oldStart,
                oldLength: range.oldLength,
                newStart: range.newStart,
                newLength: range.newLength,
                sectionHeading: range.sectionHeading,
                lines: lines,
                patch: patchLines.joined(separator: "\n") + "\n",
                addedLineCount: added,
                deletedLineCount: deleted
            )
        }

        private func lineKind(_ line: String) -> DiffReviewLineKind {
            if line.hasPrefix("+") { return .addition }
            if line.hasPrefix("-") { return .deletion }
            if line.hasPrefix("\\") { return .metadata }
            return .context
        }

        private func lineMarker(_ line: String) -> String {
            if line.hasPrefix("+") { return "+" }
            if line.hasPrefix("-") { return "-" }
            if line.hasPrefix("\\") { return "\\" }
            return " "
        }

        private func lineText(_ line: String) -> String {
            guard !line.isEmpty else { return "" }
            return String(line.dropFirst())
        }

        private func hunkRange(_ header: String) -> (
            oldStart: Int,
            oldLength: Int,
            newStart: Int,
            newLength: Int,
            sectionHeading: String?
        ) {
            let parts = header.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else {
                return (0, 0, 0, 0, nil)
            }
            let oldRange = parseRange(parts[1])
            let newRange = parseRange(parts[2])
            let heading = sectionHeading(in: header)
            return (oldRange.start, oldRange.length, newRange.start, newRange.length, heading)
        }

        private func parseRange(_ raw: String) -> (start: Int, length: Int) {
            let trimmed = raw.dropFirst()
            let components = trimmed.split(separator: ",", maxSplits: 1).map(String.init)
            let start = Int(components.first ?? "") ?? 0
            let length = components.count > 1 ? (Int(components[1]) ?? 0) : 1
            return (start, length)
        }

        private func sectionHeading(in header: String) -> String? {
            guard let firstRange = header.range(of: "@@"),
                  let secondRange = header[firstRange.upperBound...].range(of: "@@")
            else {
                return nil
            }
            let heading = header[secondRange.upperBound...].trimmingCharacters(in: .whitespaces)
            return heading.isEmpty ? nil : heading
        }
    }
}

enum DiffReviewGitError: LocalizedError, Equatable, Sendable {
    case notGitRepository
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notGitRepository:
            return String(localized: "diffReview.error.notGitRepository", defaultValue: "The selected workspace is not a git repository.")
        case .commandFailed(let detail):
            return detail.isEmpty
                ? String(localized: "diffReview.error.gitFailed", defaultValue: "Git command failed.")
                : detail
        }
    }
}

enum DiffReviewGitClient {
    static func loadSnapshot(directory: String, selectedTargetID: String) async throws -> DiffReviewSnapshot {
        try await Task.detached(priority: .utility) {
            try loadSnapshotSync(directory: directory, selectedTargetID: selectedTargetID)
        }.value
    }

    static func revertHunk(repositoryRoot: String, patch: String) async throws {
        try await Task.detached(priority: .utility) {
            _ = try runGit(
                in: repositoryRoot,
                arguments: ["apply", "-R", "--whitespace=nowarn", "-"],
                standardInput: patch,
                acceptedStatuses: [0]
            )
        }.value
    }

    private static func loadSnapshotSync(directory: String, selectedTargetID: String) throws -> DiffReviewSnapshot {
        let repositoryRoot = try runGit(
            in: directory,
            arguments: ["rev-parse", "--show-toplevel"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryRoot.isEmpty else { throw DiffReviewGitError.notGitRepository }

        let currentBranch = try? runGit(
            in: repositoryRoot,
            arguments: ["branch", "--show-current"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchesOutput = (try? runGit(
            in: repositoryRoot,
            arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"]
        ).stdout) ?? ""
        let branches = branchesOutput
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let selectedTarget = DiffReviewTarget.from(id: selectedTargetID, branches: branches)
        let hasHead = ((try? runGit(
            in: repositoryRoot,
            arguments: ["rev-parse", "--verify", "HEAD"]
        )) != nil)
        let untrackedPaths = selectedTarget == .workingTree
            ? fetchUntrackedPaths(repositoryRoot: repositoryRoot)
            : []
        let diffOutput = try diffOutput(
            repositoryRoot: repositoryRoot,
            selectedTarget: selectedTarget,
            hasHead: hasHead,
            untrackedPaths: untrackedPaths
        )
        let files = DiffReviewPatchParser.parse(
            diffOutput,
            untrackedPaths: Set(untrackedPaths)
        )

        return DiffReviewSnapshot(
            repositoryRoot: repositoryRoot,
            currentBranch: currentBranch?.isEmpty == false ? currentBranch : nil,
            branches: branches,
            selectedTarget: selectedTarget,
            files: files,
            generatedAt: Date.now
        )
    }

    private static func diffOutput(
        repositoryRoot: String,
        selectedTarget: DiffReviewTarget,
        hasHead: Bool,
        untrackedPaths: [String]
    ) throws -> String {
        let trackedDiffArguments: [String]
        switch selectedTarget {
        case .workingTree:
            trackedDiffArguments = hasHead
                ? ["diff", "--no-ext-diff", "--no-color", "--find-renames", "--unified=3", "HEAD", "--"]
                : ["diff", "--no-ext-diff", "--no-color", "--find-renames", "--unified=3", "--"]
        case .branch(let branchName):
            trackedDiffArguments = [
                "diff",
                "--no-ext-diff",
                "--no-color",
                "--find-renames",
                "--unified=3",
                "\(branchName)...HEAD",
                "--",
            ]
        }

        let trackedOutput = try runGit(
            in: repositoryRoot,
            arguments: trackedDiffArguments,
            acceptedStatuses: [0, 1]
        ).stdout
        guard selectedTarget == .workingTree, !untrackedPaths.isEmpty else {
            return trackedOutput
        }

        let untrackedOutput = untrackedPaths.prefix(100).compactMap { path in
            try? runGit(
                in: repositoryRoot,
                arguments: ["diff", "--no-ext-diff", "--no-color", "--unified=3", "--no-index", "--", "/dev/null", path],
                acceptedStatuses: [0, 1]
            ).stdout
        }.joined(separator: "\n")

        if trackedOutput.isEmpty {
            return untrackedOutput
        }
        if untrackedOutput.isEmpty {
            return trackedOutput
        }
        return trackedOutput + "\n" + untrackedOutput
    }

    private static func fetchUntrackedPaths(repositoryRoot: String) -> [String] {
        guard let result = try? runGit(
            in: repositoryRoot,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"]
        ) else {
            return []
        }
        return result.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private struct GitCommandResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runGit(
        in directory: String,
        arguments: [String],
        standardInput: String? = nil,
        acceptedStatuses: Set<Int32> = [0]
    ) throws -> GitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            inputPipe = nil
        }

        do {
            try process.run()
            if let standardInput, let inputPipe {
                inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            }
            inputPipe?.fileHandleForWriting.closeFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let result = GitCommandResult(
                status: process.terminationStatus,
                stdout: String(data: outputData, encoding: .utf8) ?? "",
                stderr: String(data: errorData, encoding: .utf8) ?? ""
            )
            guard acceptedStatuses.contains(result.status) else {
                throw DiffReviewGitError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return result
        } catch let error as DiffReviewGitError {
            throw error
        } catch {
            throw DiffReviewGitError.commandFailed(error.localizedDescription)
        }
    }
}

@MainActor
final class DiffReviewStore: ObservableObject {
    @Published private(set) var phase: DiffReviewLoadPhase = .idle
    @Published private(set) var snapshot: DiffReviewSnapshot?
    @Published private(set) var selectedTargetID = DiffReviewTarget.workingTreeID
    @Published private(set) var revertingHunkIDs: Set<String> = []

    private var directory: String?
    private var loadTask: Task<Void, Never>?
    private var liveRefreshTask: Task<Void, Never>?

    var isLoading: Bool { phase.isLoading }

    func setDirectory(_ nextDirectory: String?) {
        let trimmedDirectory = nextDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDirectory = trimmedDirectory?.isEmpty == false ? trimmedDirectory : nil
        guard directory != normalizedDirectory else {
            startLiveRefreshIfNeeded()
            return
        }

        directory = normalizedDirectory
        snapshot = nil
        revertingHunkIDs = []
        selectedTargetID = DiffReviewTarget.workingTreeID

        if normalizedDirectory == nil {
            phase = .idle
            stopLiveRefresh()
        } else {
            refresh()
            startLiveRefreshIfNeeded()
        }
    }

    func selectTarget(id: String) {
        guard selectedTargetID != id else { return }
        selectedTargetID = id
        refresh()
    }

    func refresh() {
        guard let directory else {
            phase = .idle
            snapshot = nil
            return
        }

        loadTask?.cancel()
        phase = .loading
        let targetID = selectedTargetID
        loadTask = Task { @MainActor [weak self] in
            do {
                let snapshot = try await DiffReviewGitClient.loadSnapshot(
                    directory: directory,
                    selectedTargetID: targetID
                )
                guard !Task.isCancelled else { return }
                self?.snapshot = snapshot
                self?.selectedTargetID = snapshot.selectedTarget.id
                self?.phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func revertHunk(_ hunk: DiffReviewHunk) {
        guard let snapshot, snapshot.selectedTarget.allowsHunkRevert else { return }
        guard !revertingHunkIDs.contains(hunk.id) else { return }

        revertingHunkIDs.insert(hunk.id)
        let repositoryRoot = snapshot.repositoryRoot
        let patch = hunk.patch
        Task { @MainActor [weak self] in
            do {
                try await DiffReviewGitClient.revertHunk(
                    repositoryRoot: repositoryRoot,
                    patch: patch
                )
                guard let self else { return }
                self.revertingHunkIDs.remove(hunk.id)
                self.refresh()
            } catch {
                guard let self else { return }
                self.revertingHunkIDs.remove(hunk.id)
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func stopLiveRefresh() {
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
    }

    private func startLiveRefreshIfNeeded() {
        guard directory != nil, liveRefreshTask == nil else { return }
        liveRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self, self.directory != nil else { return }
                if !self.phase.isLoading && self.revertingHunkIDs.isEmpty {
                    self.refresh()
                }
            }
        }
    }

    deinit {
        loadTask?.cancel()
        liveRefreshTask?.cancel()
    }
}
