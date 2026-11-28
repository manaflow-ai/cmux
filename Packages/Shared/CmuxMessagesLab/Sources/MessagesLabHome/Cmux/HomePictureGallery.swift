import Foundation

/// cmux: the pictures the large picture viewer (``HomePictureViewer``) steps through, and the one it shows. A
/// table card's gallery is every picture in the table, in reading order, each named by its row and column
/// ("Dark · After"), so the arrow keys walk a Before|After grid and Before and After pair for the comparison
/// (the user, 2026-11-05: "i want to be able to expand and annotate"). A bubble picture's gallery is that one
/// picture. Values only.
struct HomePictureGallery: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        /// The source as the message names it (a path, a `file:` or `https` URL, `cmux-attachment:<hash>`).
        var source: String
        /// The original the viewer loads: the file, or the web address.
        var url: URL
        /// The picture's name in the viewer's title: "row · column", or its alt text.
        var title: String
        /// Its body row and picture column (the comparison pairs pictures of one row).
        var row: Int
        var column: Int
        /// A smaller copy shown when the original cannot be loaded (a table picture's thumbnail).
        var thumbnail: URL? = nil
    }

    var items: [Item]
    /// The picture shown, always a valid index of `items`.
    var index: Int
    /// Each body row's label ("Light", "Dark"), by row; empty when the rows have none. The viewer's comparison
    /// offers them as a switch.
    var rowLabels: [Int: String] = [:]
    /// Whether the viewer opens on the comparison (a Before|After table, ``HomeCompareLayout``).
    var opensComparing = false

    init(items: [Item], index: Int) {
        self.items = items
        self.index = items.isEmpty ? 0 : min(max(0, index), items.count - 1)
    }

    /// The rows with a label, in order: the comparison's switch ("Light | Dark").
    var labeledRows: [Int] { Array(Set(items.map(\.row))).sorted().filter { rowLabels[$0] != nil } }

    /// The gallery showing row `row`'s picture in the shown picture's column (else the row's first picture);
    /// unchanged when no picture is in that row.
    func moved(toRow row: Int) -> HomePictureGallery {
        guard let current else { return self }
        let inRow = items.indices.filter { items[checked: $0]?.row == row }
        guard let first = inRow.first else { return self }
        var next = self
        next.index = inRow.first { items[checked: $0]?.column == current.column } ?? first
        return next
    }

    var current: Item? { items[checked: index] }

    /// The gallery `index + step`, stopping at the first and last picture.
    func moved(by step: Int) -> HomePictureGallery { HomePictureGallery(items: items, index: index + step) }

    /// The picture compared with `i`: the next picture of its row (Before → After), else the one before it
    /// (After → Before); nil when its row has no other picture.
    func partner(of i: Int) -> Int? {
        guard let item = items[checked: i] else { return nil }
        let row = items.indices.filter { items[checked: $0]?.row == item.row }
        guard let at = row.firstIndex(of: i), row.count > 1 else { return nil }
        return row[checked: at + 1] ?? row[checked: at - 1]
    }

    /// The pictures of `table` that have a file, opened at `source`; nil when `source` is not one of them.
    /// A title is the row's first text cell and the picture column's header ("Light · Before"); a table without
    /// them uses the picture's alt text.
    init?(table: HomeTable, opening source: String) {
        let header = table.header.map { HomeTableCell(markdown: $0) }
        var items: [Item] = []
        var labels: [Int: String] = [:]
        for (r, row) in table.rows.enumerated() {
            let cells = row.map { HomeTableCell(markdown: $0) }
            let label = cells.first { $0.images.isEmpty && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }?.text
            if let label { labels[r] = label.trimmingCharacters(in: .whitespaces) }
            var column = 0
            for (c, cell) in cells.enumerated() {
                for image in cell.images {
                    guard let path = table.pictures?[image.source] else { continue }
                    let url = HomeTablePictures.original(image.source) ?? URL(fileURLWithPath: path)
                    let name = header[checked: c]?.text.trimmingCharacters(in: .whitespaces) ?? ""
                    let parts = [label, name.isEmpty ? nil : name].compactMap { $0 }
                    let title = parts.isEmpty ? (image.alt.isEmpty ? CmuxStrings.pictureUntitled : image.alt) : parts.joined(separator: " · ")
                    items.append(Item(source: image.source, url: url, title: title, row: r, column: column, thumbnail: URL(fileURLWithPath: path)))
                    column += 1
                }
            }
        }
        guard let at = items.firstIndex(where: { $0.source == source }) else { return nil }
        self.init(items: items, index: at)
        rowLabels = labels
        opensComparing = HomeCompareLayout.matches(table)
    }
}
