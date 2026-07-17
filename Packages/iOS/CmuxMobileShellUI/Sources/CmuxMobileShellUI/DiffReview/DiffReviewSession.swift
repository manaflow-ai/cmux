import CmuxDiffModel
import Foundation
import Observation

@MainActor
@Observable
final class DiffReviewSession {
    private(set) var files: [DiffFileSummary]
    private(set) var currentFileIndex: Int
    private(set) var currentHunkIndex: Int
    private(set) var bookmark: DiffReviewBookmark?
    private(set) var navigationGeneration: Int
    private var hunkCountsByPath: [String: Int]
    /// Set when backward navigation crossed into a file whose hunk count is not
    /// loaded yet; `recordHunkCount` then lands on that file's LAST hunk instead
    /// of leaving the index at zero.
    private var pendingSeekToLastHunk = false

    init(files: [DiffFileSummary] = []) {
        self.files = files
        self.currentFileIndex = 0
        self.currentHunkIndex = 0
        self.bookmark = nil
        self.navigationGeneration = 0
        self.hunkCountsByPath = [:]
    }

    var currentFile: DiffFileSummary? {
        guard files.indices.contains(currentFileIndex) else { return nil }
        return files[currentFileIndex]
    }

    var currentHunkCount: Int {
        currentHunkCountIfLoaded ?? 0
    }

    private var currentHunkCountIfLoaded: Int? {
        guard let path = currentFile?.path else { return nil }
        return hunkCountsByPath[path]
    }

    var hasJumpBackTarget: Bool {
        guard let bookmark, let currentFile else { return false }
        return bookmark.filePath != currentFile.path || bookmark.hunkIndex != currentHunkIndex
    }

    var canMoveBackward: Bool {
        currentHunkIndex > 0 || currentFileIndex > 0
    }

    var canMoveForward: Bool {
        guard let count = currentHunkCountIfLoaded else { return false }
        if count > 0, currentHunkIndex + 1 < count {
            return true
        }
        return currentFileIndex + 1 < files.count
    }

    func setFiles(_ files: [DiffFileSummary]) {
        let selectedPath = currentFile?.path
        let previousSnapshotByPath = Dictionary(
            self.files.map { ($0.path, $0.snapshotToken) },
            uniquingKeysWith: { first, _ in first }
        )
        let changedSnapshotPaths = Set<String>(files.compactMap { file -> String? in
            guard let previousSnapshot = previousSnapshotByPath[file.path],
                  previousSnapshot != file.snapshotToken else {
                return nil
            }
            return file.path
        })
        self.files = files
        let validPaths = Set(files.map(\.path))
        hunkCountsByPath = hunkCountsByPath.filter { path, _ in
            validPaths.contains(path) && !changedSnapshotPaths.contains(path)
        }
        // A bookmark whose file left the list would keep showing the Jump
        // Back pill while jumpToBookmark silently no-ops.
        if let bookmark {
            let bookmarkIsInvalid = !files.contains(where: { $0.path == bookmark.filePath })
                || changedSnapshotPaths.contains(bookmark.filePath)
            if bookmarkIsInvalid {
                self.bookmark = nil
            }
        }
        if self.files.isEmpty {
            currentFileIndex = 0
            currentHunkIndex = 0
            pendingSeekToLastHunk = false
            return
        }
        if let selectedPath,
           let selectedIndex = self.files.firstIndex(where: { $0.path == selectedPath }) {
            currentFileIndex = selectedIndex
            if changedSnapshotPaths.contains(selectedPath) {
                currentHunkIndex = 0
                pendingSeekToLastHunk = false
            }
        } else {
            currentFileIndex = min(currentFileIndex, self.files.count - 1)
            currentHunkIndex = 0
            pendingSeekToLastHunk = false
        }
    }

    func openFile(at index: Int) {
        guard files.indices.contains(index) else { return }
        currentFileIndex = index
        currentHunkIndex = 0
        pendingSeekToLastHunk = false
        navigationGeneration &+= 1
    }

    func openFile(path: String) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        openFile(at: index)
    }

    func recordHunkCount(_ count: Int, for path: String) {
        hunkCountsByPath[path] = count
        if let bookmark,
           bookmark.filePath == path,
           bookmark.hunkIndex >= count {
            self.bookmark = DiffReviewBookmark(filePath: path, hunkIndex: max(0, count - 1))
        }
        guard currentFile?.path == path else { return }
        if pendingSeekToLastHunk {
            pendingSeekToLastHunk = false
            currentHunkIndex = max(0, count - 1)
        } else if currentHunkIndex >= count {
            currentHunkIndex = max(0, count - 1)
        }
    }

    func moveForward() {
        guard canMoveForward else { return }
        pendingSeekToLastHunk = false
        let count = currentHunkCount
        if count > 0, currentHunkIndex + 1 < count {
            currentHunkIndex += 1
        } else {
            currentFileIndex += 1
            currentHunkIndex = 0
        }
        navigationGeneration &+= 1
    }

    func moveBackward() {
        guard canMoveBackward else { return }
        pendingSeekToLastHunk = false
        if currentHunkIndex > 0 {
            currentHunkIndex -= 1
        } else {
            currentFileIndex -= 1
            if let loadedCount = currentHunkCountIfLoaded {
                currentHunkIndex = max(0, loadedCount - 1)
            } else {
                // Hunk count unknown until the file loads; land on the last
                // hunk once `recordHunkCount` delivers it.
                currentHunkIndex = 0
                pendingSeekToLastHunk = true
            }
        }
        navigationGeneration &+= 1
    }

    func markBookmark() {
        guard let currentFile else { return }
        bookmark = DiffReviewBookmark(filePath: currentFile.path, hunkIndex: currentHunkIndex)
    }

    func jumpToBookmark() {
        guard let bookmark,
              let fileIndex = files.firstIndex(where: { $0.path == bookmark.filePath }) else {
            return
        }
        currentFileIndex = fileIndex
        pendingSeekToLastHunk = false
        let count = hunkCountsByPath[bookmark.filePath] ?? 0
        currentHunkIndex = count > 0 ? min(bookmark.hunkIndex, count - 1) : bookmark.hunkIndex
        navigationGeneration &+= 1
    }
}
