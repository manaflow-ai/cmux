/// A grid's selection as a value: the selected tile positions and the
/// anchor a Shift-click extends from. ``FileGridView`` keeps one and runs
/// every click, Cmd-A and Esc through it, so the rules below are the only
/// selection rules (macOS Finder and Photos):
///
/// - a click selects one tile and makes it the anchor;
/// - Cmd-click adds or removes one tile and makes it the anchor;
/// - Shift-click selects the run from the anchor to the tile (the anchor stays);
/// - Shift-Cmd-click adds that run to the selection;
/// - Cmd-A selects every tile; Esc selects none.
///
/// ```swift
/// var selection = FileGridSelection()
/// selection = selection.clicking(2, .select)   // [2]
/// selection = selection.clicking(5, .range)    // [2, 3, 4, 5]
/// selection = selection.clicking(3, .toggle)   // [2, 4, 5], anchor 3
/// ```
public nonisolated struct FileGridSelection: Sendable, Hashable {
    /// The selected tile positions, in grid order (0 is the first tile).
    public private(set) var indices: Set<Int>
    /// Where a Shift-click extends from: the last plain or Cmd-clicked tile; nil before any.
    public private(set) var anchor: Int?

    /// Makes a selection.
    ///
    /// - Parameters:
    ///   - indices: the selected positions (default: none).
    ///   - anchor: where Shift-click extends from (default: none).
    public init(indices: Set<Int> = [], anchor: Int? = nil) {
        self.indices = indices
        self.anchor = anchor
    }

    /// The selection after a click of `kind` on the tile at `index`.
    ///
    /// A Shift-click without an anchor (nothing clicked yet) acts as a plain or Cmd-click.
    ///
    /// - Parameters:
    ///   - index: the clicked tile's position.
    ///   - kind: what the click's modifier keys ask for.
    /// - Returns: the new selection.
    public func clicking(_ index: Int, _ kind: FileGridClickKind) -> FileGridSelection {
        switch kind {
        case .select:
            return FileGridSelection(indices: [index], anchor: index)
        case .toggle:
            var next = indices
            if next.contains(index) { next.remove(index) } else { next.insert(index) }
            return FileGridSelection(indices: next, anchor: index)
        case .range:
            guard let anchor else { return clicking(index, .select) }
            return FileGridSelection(indices: Self.run(anchor, index), anchor: anchor)
        case .addRange:
            guard let anchor else { return clicking(index, .toggle) }
            return FileGridSelection(indices: indices.union(Self.run(anchor, index)), anchor: anchor)
        }
    }

    /// Every one of `count` tiles selected (Cmd-A); the anchor stays.
    ///
    /// - Parameter count: how many tiles the grid shows.
    /// - Returns: the new selection.
    public func selectingAll(count: Int) -> FileGridSelection {
        FileGridSelection(indices: Set(0..<max(0, count)), anchor: anchor.flatMap { $0 < count ? $0 : nil })
    }

    /// No tile selected and no anchor (Esc).
    public func cleared() -> FileGridSelection { FileGridSelection() }

    private static func run(_ from: Int, _ to: Int) -> Set<Int> {
        Set(min(from, to)...max(from, to))
    }
}
