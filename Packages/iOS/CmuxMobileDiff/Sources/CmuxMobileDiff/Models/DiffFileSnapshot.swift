internal import CmuxMobileRPC

/// An immutable changed-file summary and its current rendered rows.
struct DiffFileSnapshot: Identifiable, Sendable, Equatable {
    /// Stable identity derived from the new-side path.
    var id: String { path }
    /// New-side repository-relative path.
    let path: String
    /// Old-side path for copies and renames.
    let oldPath: String?
    /// Git status classification.
    let status: MobileChangesFileStatus
    /// Added line count.
    let additions: Int
    /// Deleted line count.
    let deletions: Int
    /// Whether content is binary.
    let isBinary: Bool
    /// Whether loading requires explicit confirmation.
    let isLarge: Bool
    /// Digest used by device-local viewed state.
    let patchDigest: String
    /// Maximum old-side gutter digits.
    let oldGutterDigits: Int
    /// Maximum new-side gutter digits.
    let newGutterDigits: Int
    /// Current immutable render rows.
    let rows: [DiffRowSnapshot]
    /// Whether the file section is collapsed.
    let isCollapsed: Bool
    /// Whether the current digest is marked viewed.
    let isViewed: Bool
    /// Whether an RPC is active for this file.
    let isLoading: Bool
    /// Number of pages loaded for a gated diff.
    let loadedPageCount: Int
    /// Localized file-scoped failure text.
    let errorMessage: String?

    /// Creates a file rendering snapshot.
    init(
        file: MobileChangesFile,
        rows: [DiffRowSnapshot],
        isCollapsed: Bool,
        isViewed: Bool,
        isLoading: Bool,
        loadedPageCount: Int = 0,
        errorMessage: String? = nil
    ) {
        path = file.path
        oldPath = file.oldPath
        status = file.status
        additions = file.additions
        deletions = file.deletions
        isBinary = file.isBinary
        isLarge = file.isLarge
        patchDigest = file.patchDigest
        oldGutterDigits = Self.gutterDigits(rows.compactMap(\.oldLineNumber).max())
        newGutterDigits = Self.gutterDigits(rows.compactMap(\.newLineNumber).max())
        self.rows = rows
        self.isCollapsed = isCollapsed
        self.isViewed = isViewed
        self.isLoading = isLoading
        self.loadedPageCount = loadedPageCount
        self.errorMessage = errorMessage
    }

    /// Returns the fixed gutter width in decimal digits for a maximum line number.
    /// - Parameter maximum: Maximum visible line number.
    /// - Returns: At least one decimal digit.
    static func gutterDigits(_ maximum: Int?) -> Int {
        String(max(1, maximum ?? 1)).count
    }
}
