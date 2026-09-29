/// What a viewer had open in one tree: expansion, selection and scroll.
///
/// Paths are relative to the tree root so a state is small and survives
/// the root being displayed through a different absolute prefix.
public struct FileTreeViewState: Codable, Sendable, Equatable {
    /// Expanded directories, relative to the root.
    public var expandedPaths: [String]
    /// Selected rows, relative to the root.
    public var selectedPaths: [String]
    /// The keyboard anchor among ``selectedPaths``.
    public var anchorPath: String?
    /// The row at the top of the viewport, relative to the root.
    public var topVisiblePath: String?
    /// How far the viewport starts below the top of ``topVisiblePath``, in points.
    public var topVisibleOffset: Double

    /// Creates a view state.
    /// - Parameters:
    ///   - expandedPaths: Expanded directories relative to the root.
    ///   - selectedPaths: Selected rows relative to the root.
    ///   - anchorPath: The keyboard anchor row.
    ///   - topVisiblePath: The first visible row.
    ///   - topVisibleOffset: Points between that row's top and the viewport top.
    public init(
        expandedPaths: [String] = [],
        selectedPaths: [String] = [],
        anchorPath: String? = nil,
        topVisiblePath: String? = nil,
        topVisibleOffset: Double = 0
    ) {
        self.expandedPaths = expandedPaths
        self.selectedPaths = selectedPaths
        self.anchorPath = anchorPath
        self.topVisiblePath = topVisiblePath
        self.topVisibleOffset = topVisibleOffset
    }

    /// Converts an absolute path under `root` to the stored relative form.
    /// - Returns: `""` for the root itself, `nil` for paths outside it.
    public static func relativePath(_ path: String, root: String) -> String? {
        if path == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Converts a stored relative path back to an absolute path under `root`.
    public static func absolutePath(_ relative: String, root: String) -> String {
        if relative.isEmpty { return root }
        return root == "/" ? "/" + relative : root + "/" + relative
    }
}
