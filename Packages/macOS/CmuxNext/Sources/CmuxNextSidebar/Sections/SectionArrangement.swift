import Foundation

/// How a section lays out its items, like a small flexbox
/// (plans/cmux-next/sidebar-sections.md 4): rows, one line, or a grid.
/// Wire: `{"layout": "list"|"inline"|"grid", "align": …, "gap": n, "columns": n}`,
/// every key optional.
public nonisolated struct SectionArrangement: Hashable, Sendable, Codable {
    public enum Layout: String, Hashable, Sendable, Codable, CaseIterable {
        /// One item per row: icon and label.
        case list
        /// Items side by side on one line: icon and label while they fit,
        /// icons only when they do not, a second line only when icons do
        /// not fit either.
        case inline
        /// Tiles in columns.
        case grid
    }

    /// Where leftover space on a line goes (inline, and grid with fixed
    /// columns; a grid with fitted columns stretches its tiles instead).
    public enum Alignment: String, Hashable, Sendable, Codable, CaseIterable {
        case leading
        case center
        case trailing
        /// Leftover space between items (inline), or stretched tiles (grid).
        case fill
    }

    public var layout: Layout
    public var align: Alignment
    /// Points between items on a line; nil = the design default.
    public var gap: Int?
    /// Grid columns; nil = as many as fit.
    public var columns: Int?

    public init(layout: Layout = .list, align: Alignment = .leading, gap: Int? = nil, columns: Int? = nil) {
        self.layout = layout
        self.align = align
        self.gap = gap
        self.columns = columns
    }

    public static let list = SectionArrangement()
    public static let inline = SectionArrangement(layout: .inline)
    public static let grid = SectionArrangement(layout: .grid)

    /// Valid ranges (invariant L4).
    public static let gapRange = 0...32
    public static let columnsRange = 1...12

    enum CodingKeys: String, CodingKey { case layout, align, gap, columns }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown values (from a newer app) fall back instead of failing the
        // whole document (L5); this client never writes the document back.
        layout = (try? c.decodeIfPresent(String.self, forKey: .layout)).flatMap(Layout.init(rawValue:)) ?? .list
        align = (try? c.decodeIfPresent(String.self, forKey: .align)).flatMap(Alignment.init(rawValue:)) ?? .leading
        gap = try c.decodeIfPresent(Int.self, forKey: .gap)
        columns = try c.decodeIfPresent(Int.self, forKey: .columns)
    }

    public var isValid: Bool {
        (gap.map(Self.gapRange.contains) ?? true) && (columns.map(Self.columnsRange.contains) ?? true)
    }
}
