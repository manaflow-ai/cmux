import Foundation
public import CmuxMobileShellModel
public import Observation

/// Native metadata for one file rendered by the shared web diff viewer.
public struct MobileDiffFile: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let path: String
    public let added: Int
    public let deleted: Int

    public init(id: String, path: String, added: Int, deleted: Int) {
        self.id = id
        self.path = path
        self.added = added
        self.deleted = deleted
    }

    public var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Main-actor state shared by the native diff chrome and its `WKWebView`.
@MainActor
@Observable
public final class MobileDiffState {
    public private(set) var document: MobileDiffDocument?
    public private(set) var files: [MobileDiffFile] = []
    public private(set) var selectedFileID: String?
    public private(set) var errorMessage: String?
    public private(set) var isLoading = false
    public private(set) var generation = 0
    private var fileIndexByID: [String: Int] = [:]

    public init() {}

    public var selectedFile: MobileDiffFile? {
        guard let selectedFileIndex else { return files.first }
        return files[selectedFileIndex]
    }

    public var selectedFileIndex: Int? {
        guard let selectedFileID else { return files.indices.first }
        return fileIndexByID[selectedFileID]
    }

    public var canSelectPrevious: Bool {
        guard let selectedFileIndex else { return false }
        return selectedFileIndex > files.startIndex
    }

    public var canSelectNext: Bool {
        guard let selectedFileIndex else { return false }
        return selectedFileIndex + 1 < files.endIndex
    }

    public func beginLoading() {
        isLoading = true
        errorMessage = nil
    }

    public func load(_ document: MobileDiffDocument) {
        self.document = document
        files = []
        fileIndexByID = [:]
        selectedFileID = nil
        errorMessage = nil
        isLoading = false
        generation &+= 1
    }

    public func fail(message: String) {
        isLoading = false
        errorMessage = message
    }

    public func updateFiles(_ files: [MobileDiffFile], selectedFileID: String?) {
        self.files = files
        fileIndexByID = [:]
        for (index, file) in files.enumerated() where fileIndexByID[file.id] == nil {
            fileIndexByID[file.id] = index
        }
        if let selectedFileID, fileIndexByID[selectedFileID] != nil {
            self.selectedFileID = selectedFileID
        } else if self.selectedFileID.flatMap({ fileIndexByID[$0] }) == nil {
            self.selectedFileID = files.first?.id
        }
    }

    public func selectFile(id: String) {
        guard fileIndexByID[id] != nil else { return }
        selectedFileID = id
    }

    public func selectPrevious() {
        guard let selectedFileIndex, selectedFileIndex > files.startIndex else { return }
        selectedFileID = files[files.index(before: selectedFileIndex)].id
    }

    public func selectNext() {
        guard let selectedFileIndex, selectedFileIndex + 1 < files.endIndex else { return }
        selectedFileID = files[files.index(after: selectedFileIndex)].id
    }
}
