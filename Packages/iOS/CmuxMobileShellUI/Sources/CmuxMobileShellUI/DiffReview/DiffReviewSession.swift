import CmuxMobileRPC
import Foundation
import Observation

@MainActor
@Observable
final class DiffReviewSession {
    struct Bookmark: Equatable {
        let filePath: String
        let hunkIndex: Int
    }

    private(set) var files: [MobileWorkspaceDiffStatusResponse.File]
    private(set) var currentFileIndex: Int
    private(set) var currentHunkIndex: Int
    private(set) var bookmark: Bookmark?
    private(set) var navigationGeneration: Int
    private var hunkCountsByPath: [String: Int]
    /// Set when backward navigation crossed into a file whose hunk count is not
    /// loaded yet; `recordHunkCount` then lands on that file's LAST hunk instead
    /// of leaving the index at zero.
    private var pendingSeekToLastHunk = false

    init(files: [MobileWorkspaceDiffStatusResponse.File] = []) {
        self.files = files
        self.currentFileIndex = 0
        self.currentHunkIndex = 0
        self.bookmark = nil
        self.navigationGeneration = 0
        self.hunkCountsByPath = [:]
    }

    var currentFile: MobileWorkspaceDiffStatusResponse.File? {
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

    func setFiles(_ files: [MobileWorkspaceDiffStatusResponse.File]) {
        self.files = files
        hunkCountsByPath = hunkCountsByPath.filter { path, _ in
            files.contains { $0.path == path }
        }
        // A bookmark whose file left the list would keep showing the Jump
        // Back pill while jumpToBookmark silently no-ops.
        if let bookmark, !files.contains(where: { $0.path == bookmark.filePath }) {
            self.bookmark = nil
        }
        if self.files.isEmpty {
            currentFileIndex = 0
            currentHunkIndex = 0
            pendingSeekToLastHunk = false
            return
        }
        if currentFileIndex >= self.files.count {
            currentFileIndex = 0
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

    func recordHunkCount(_ count: Int, for path: String) {
        hunkCountsByPath[path] = count
        guard currentFile?.path == path else { return }
        if pendingSeekToLastHunk {
            pendingSeekToLastHunk = false
            currentHunkIndex = max(0, count - 1)
        } else if count > 0, currentHunkIndex >= count {
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
        bookmark = Bookmark(filePath: currentFile.path, hunkIndex: currentHunkIndex)
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
