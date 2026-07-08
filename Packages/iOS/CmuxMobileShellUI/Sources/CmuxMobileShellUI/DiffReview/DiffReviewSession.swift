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
        if self.files.isEmpty {
            currentFileIndex = 0
            currentHunkIndex = 0
            return
        }
        if currentFileIndex >= self.files.count {
            currentFileIndex = 0
            currentHunkIndex = 0
        }
    }

    func openFile(at index: Int) {
        guard files.indices.contains(index) else { return }
        currentFileIndex = index
        currentHunkIndex = 0
        navigationGeneration &+= 1
    }

    func recordHunkCount(_ count: Int, for path: String) {
        hunkCountsByPath[path] = count
        if currentFile?.path == path, count > 0, currentHunkIndex >= count {
            currentHunkIndex = max(0, count - 1)
        }
    }

    func moveForward() {
        guard canMoveForward else { return }
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
        if currentHunkIndex > 0 {
            currentHunkIndex -= 1
        } else {
            currentFileIndex -= 1
            let previousCount = currentHunkCount
            currentHunkIndex = max(0, previousCount - 1)
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
        let count = hunkCountsByPath[bookmark.filePath] ?? 0
        currentHunkIndex = count > 0 ? min(bookmark.hunkIndex, count - 1) : bookmark.hunkIndex
        navigationGeneration &+= 1
    }
}
