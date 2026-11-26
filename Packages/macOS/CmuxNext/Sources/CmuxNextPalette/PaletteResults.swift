/// One rendered row.
public struct PaletteRow: Identifiable {
    public let item: PaletteItem
    /// Scalar offsets into `item.title` that matched the query.
    public let highlights: [Int]
    public let score: Int

    public var id: String { item.id }
}

/// A titled group of rendered rows.
public struct PaletteResultSection: Identifiable {
    public let section: PaletteSection
    public let rows: [PaletteRow]

    public var id: String { section.id }
    public var title: String { section.title }
}
