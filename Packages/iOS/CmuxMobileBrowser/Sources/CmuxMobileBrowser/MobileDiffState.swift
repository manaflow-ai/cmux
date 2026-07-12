public import CmuxMobileShellModel
public import Observation

/// Main-actor state shared by the native diff chrome and its `WKWebView`.
@MainActor
@Observable
public final class MobileDiffState {
    /// The diff document currently rendered by the web view.
    public private(set) var document: MobileDiffDocument?
    /// Native metadata for the changed files in display order.
    public private(set) var files: [MobileDiffFile] = []
    /// The identifier of the file selected in native and web views.
    public private(set) var selectedFileID: String?
    /// A localized message describing the latest loading failure.
    public private(set) var errorMessage: String?
    /// Whether the diff document is currently being refreshed.
    public private(set) var isLoading = false
    /// A monotonically increasing value identifying the rendered document.
    public private(set) var generation = 0
    private var fileIndexByID: [String: Int] = [:]

    /// Creates empty mobile diff state.
    public init() {}

    /// The selected file, or the first file when no explicit selection exists.
    public var selectedFile: MobileDiffFile? {
        guard let selectedFileIndex else { return files.first }
        return files[selectedFileIndex]
    }

    /// The index of the selected file, or the first valid index by default.
    public var selectedFileIndex: Int? {
        guard let selectedFileID else { return files.indices.first }
        return fileIndexByID[selectedFileID]
    }

    /// Whether a file exists before the current selection.
    public var canSelectPrevious: Bool {
        guard let selectedFileIndex else { return false }
        return selectedFileIndex > files.startIndex
    }

    /// Whether a file exists after the current selection.
    public var canSelectNext: Bool {
        guard let selectedFileIndex else { return false }
        return selectedFileIndex + 1 < files.endIndex
    }

    /// Marks the diff as loading and clears the previous error.
    public func beginLoading() {
        isLoading = true
        errorMessage = nil
    }

    /// Replaces the rendered document and resets its native file metadata.
    public func load(_ document: MobileDiffDocument) {
        self.document = document
        files = []
        fileIndexByID = [:]
        selectedFileID = nil
        errorMessage = nil
        isLoading = false
        generation &+= 1
    }

    /// Ends loading and presents a localized error message.
    public func fail(message: String) {
        isLoading = false
        errorMessage = message
    }

    /// Synchronizes native file metadata and selection from the web renderer.
    public func updateFiles(_ files: [MobileDiffFile], selectedFileID: String?) {
        self.files = files
        fileIndexByID = [:]
        for (index, file) in files.enumerated() where fileIndexByID[file.id] == nil {
            fileIndexByID[file.id] = index
        }
        if self.selectedFileID.flatMap({ fileIndexByID[$0] }) != nil {
            return
        }
        if let selectedFileID, fileIndexByID[selectedFileID] != nil {
            self.selectedFileID = selectedFileID
        } else {
            self.selectedFileID = files.first?.id
        }
    }

    /// Selects the file with the supplied renderer identifier when it exists.
    public func selectFile(id: String) {
        guard fileIndexByID[id] != nil else { return }
        selectedFileID = id
    }

    /// Selects the file immediately before the current selection.
    public func selectPrevious() {
        guard let selectedFileIndex, selectedFileIndex > files.startIndex else { return }
        selectedFileID = files[files.index(before: selectedFileIndex)].id
    }

    /// Selects the file immediately after the current selection.
    public func selectNext() {
        guard let selectedFileIndex, selectedFileIndex + 1 < files.endIndex else { return }
        selectedFileID = files[files.index(after: selectedFileIndex)].id
    }
}
