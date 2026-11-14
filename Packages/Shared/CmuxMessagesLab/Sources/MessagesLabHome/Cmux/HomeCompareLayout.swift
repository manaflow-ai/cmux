import AppKit
import CoreGraphics
import Foundation

/// cmux: a Before|After table laid out as large pairs (the user, 2026-11-05, msg 23164: "before/after ui should
/// make all of the things visible better, instead of just being gallery view ... rn it doesn't look very
/// clean"). A table whose corner cell is empty, whose other header cells name the pictures ("Before",
/// "After") and whose rows each hold a label ("Light", "Dark") and one picture per column draws without a
/// grid: each row is its pictures side by side across the card's full width, each in a cell of one size.
///
/// The chat column's layout (``HomeChatColumn``; the user, 2026-11-09: "fix all alignment issues"): a picture's
/// name ("Light · Before", as the viewer titles it) is a caption over its cell, at the cell's leading edge, never
/// over the picture (a pill on the picture's corner covered what the shot shows); the cells of a pair are one
/// size, and a picture of another shape sits in the middle of its cell, so a pair shares one centre line; cells
/// and captions start one content inset inside the card, where a bubble's text does. A click opens the row's
/// pair in the picture viewer's slider (``HomePictureViewer``), with the rows as a switch. Pure CoreText, any thread.
struct HomeCompareLayout {
    static let captionHeight: CGFloat = 20
    static let pictureGap: CGFloat = 10
    static let rowGap: CGFloat = 14
    /// A pair's pictures stop at this height (a tall phone shot does not fill the chat).
    static let pictureMaxHeight: CGFloat = 460

    struct Picture {
        var slot: HomeTableGrid.Slot
        /// The picture's name over its cell ("Light · Before").
        var caption: NSAttributedString
        /// The caption's frame, relative to the card's top left: one line over the cell, from its leading edge.
        var captionRect: CGRect
        /// The picture's cell, relative to the card's top left: every cell of a row has one size.
        var cell: CGRect
        /// The picture's frame in its cell (its own shape, in the cell's middle).
        var rect: CGRect
    }

    struct Row {
        /// The row's first caption's frame (the pair's leading edge).
        var captionRect: CGRect
        var pictures: [Picture]
    }

    let rows: [Row]
    let width: CGFloat
    let height: CGFloat

    /// Whether `table` is a comparison: an empty corner, two or more named picture columns, and body rows of a
    /// text label and one picture per column. Its pictures need not be loaded.
    static func matches(_ table: HomeTable) -> Bool {
        guard table.columns >= 3, !table.rows.isEmpty,
              table.header[0].trimmingCharacters(in: .whitespaces).isEmpty,
              table.header.dropFirst().allSatisfy({ !HomeTableCell(markdown: $0).text.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return false }
        return table.rows.allSatisfy { row in
            let cells = row.map { HomeTableCell(markdown: $0) }
            guard let label = cells.first, label.images.isEmpty, !label.text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            return cells.dropFirst().allSatisfy { $0.images.count == 1 }
        }
    }

    /// The large-pairs layout of `table` at `available` points, from the grid's picture slots (rows as the grid's
    /// cells, header first); nil when `table` is not a comparison or a picture has neither a file nor a skeleton
    /// (its alt text shows, in the grid).
    init?(_ table: HomeTable, slots: [[[HomeTableGrid.Slot]]], available: CGFloat) {
        guard Self.matches(table) else { return nil }
        let pad = HomeChatColumn.contentInset
        let columns = table.columns - 1
        let inner = max(1, available - 2 * pad)
        let each = max(1, ((inner - Self.pictureGap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
        let titles = table.header.dropFirst().map { HomeTableCell(markdown: $0).text.trimmingCharacters(in: .whitespaces) }
        let font = HomeFonts.system(ofSize: 12, weight: .semibold)
        var rows: [Row] = []
        var y = pad
        for (r, row) in table.rows.enumerated() {
            let label = HomeTableCell(markdown: row[0]).text.trimmingCharacters(in: .whitespaces)
            var found: [(slot: HomeTableGrid.Slot, size: CGSize)] = []
            for c in 0..<columns {
                guard let slot = slots[checked: r + 1]?[checked: c + 1]?.first else { return nil }
                found.append((slot, Self.pictureSize(pixels: slot.pixels, width: each)))
            }
            // One cell size for the row: as tall as its tallest picture.
            let tall = found.map(\.size.height).max() ?? 0
            let top = y + Self.captionHeight
            var pictures: [Picture] = []
            for (c, item) in found.enumerated() {
                let cell = CGRect(x: pad + CGFloat(c) * (each + Self.pictureGap), y: top, width: each, height: tall)
                let rect = CGRect(x: (cell.midX - item.size.width / 2).rounded(), y: (cell.midY - item.size.height / 2).rounded(),
                                  width: item.size.width, height: item.size.height)
                let name = [label, titles[checked: c] ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                let caption = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: Fixture.secondaryText])
                pictures.append(Picture(slot: item.slot, caption: caption,
                                        captionRect: CGRect(x: cell.minX, y: y, width: each, height: Self.captionHeight - 4),
                                        cell: cell, rect: rect))
            }
            rows.append(Row(captionRect: pictures.first?.captionRect ?? .zero, pictures: pictures))
            y = top + tall + (r < table.rows.count - 1 ? Self.rowGap : 0)
        }
        self.rows = rows
        width = available
        height = (y + pad).rounded(.up)
    }

    /// A picture of `pixels` at most `width` wide and ``pictureMaxHeight`` tall, never beyond its thumbnail's points.
    static func pictureSize(pixels: CGSize, width: CGFloat) -> CGSize {
        let thumb = HomeTableGrid.thumbnailPixels(pixels)
        let w = thumb.width / 2, h = thumb.height / 2
        guard w > 0, h > 0 else { return .zero }
        let scale = min(width / w, pictureMaxHeight / h)
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }

    func draw(_ ctx: CGContext, at origin: CGPoint) {
        let card = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        HomeCardDraw.background(ctx, card)
        for row in rows {
            for picture in row.pictures {
                // One line: a name longer than its cell stops at the cell's edge.
                let caption = picture.captionRect.offsetBy(dx: origin.x, dy: origin.y)
                ctx.saveGState()
                ctx.clip(to: caption)
                HomeCardDraw.text(ctx, picture.caption, in: CGRect(x: caption.minX, y: caption.minY, width: 10_000, height: caption.height), alignment: .leading)
                ctx.restoreGState()
                let cell = picture.cell.offsetBy(dx: origin.x, dy: origin.y)
                let rect = picture.rect.offsetBy(dx: origin.x, dy: origin.y)
                // A picture of another shape than its cell: the cell shows behind it, so the pair reads as two equal frames.
                if rect.width < cell.width - 1 || rect.height < cell.height - 1 { HomeCardDraw.skeleton(ctx, cell) }
                if let image = picture.slot.image { HomeCardDraw.picture(ctx, image, in: rect) } else { HomeCardDraw.skeleton(ctx, rect) }
            }
        }
    }

    func pictureRects(at origin: CGPoint) -> [HomeTableGrid.PictureRect] {
        rows.flatMap { row in
            row.pictures.map { HomeTableGrid.PictureRect(source: $0.slot.source, rect: $0.rect.offsetBy(dx: origin.x, dy: origin.y), loading: $0.slot.loading) }
        }
    }
}
