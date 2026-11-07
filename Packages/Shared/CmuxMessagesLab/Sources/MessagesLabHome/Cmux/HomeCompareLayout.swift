import AppKit
import CoreGraphics
import Foundation

/// cmux: a Before|After table laid out as large pairs (the user, 2026-11-05, msg 23164: "before/after ui should
/// make all of the things visible better, instead of just being gallery view ... rn it doesn't look very
/// clean"). A table whose corner cell is empty, whose other header cells name the pictures ("Before",
/// "After") and whose rows each hold a label ("Light", "Dark") and one picture per column draws without a
/// grid: each row is a caption with its pictures side by side across the card's full width, each picture
/// named by a pill on its bottom-left corner (a window shot keeps its window buttons on top). A click opens the row's pair in the picture viewer's slider
/// (``HomePictureViewer``), with the rows as a switch. Pure CoreText, any thread.
struct HomeCompareLayout {
    static let captionHeight: CGFloat = 22
    static let pictureGap: CGFloat = 10
    static let rowGap: CGFloat = 16
    /// A pair's pictures stop at this height (a tall phone shot does not fill the chat).
    static let pictureMaxHeight: CGFloat = 460
    static let pillHeight: CGFloat = 20
    static let pillInset: CGFloat = 8

    struct Picture {
        var slot: HomeTableGrid.Slot
        /// The picture's column name ("Before"), drawn as its pill.
        var title: String
        /// Its frame, relative to the card's top left.
        var rect: CGRect
    }

    struct Row {
        var caption: NSAttributedString
        /// The caption's frame, relative to the card's top left.
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
        let pad = HomeTableGrid.pad
        let columns = table.columns - 1
        let inner = max(1, available - 2 * pad)
        let each = max(1, ((inner - Self.pictureGap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
        let titles = table.header.dropFirst().map { HomeTableCell(markdown: $0).text.trimmingCharacters(in: .whitespaces) }
        var rows: [Row] = []
        var y = pad
        for (r, row) in table.rows.enumerated() {
            let label = HomeTableCell(markdown: row[0]).text.trimmingCharacters(in: .whitespaces)
            var pictures: [Picture] = []
            let top = y + Self.captionHeight
            var tallest: CGFloat = 0
            for c in 0..<columns {
                guard let slot = slots[checked: r + 1]?[checked: c + 1]?.first else { return nil }
                let size = Self.pictureSize(pixels: slot.pixels, width: each)
                let x = pad + CGFloat(c) * (each + Self.pictureGap)
                // A narrower picture (a taller aspect) sits in the middle of its column.
                let rect = CGRect(x: (x + (each - size.width) / 2).rounded(), y: top, width: size.width, height: size.height)
                pictures.append(Picture(slot: slot, title: titles[checked: c] ?? "", rect: rect))
                tallest = max(tallest, size.height)
            }
            let caption = NSAttributedString(string: label, attributes: [
                .font: HomeFonts.system(ofSize: 12, weight: .semibold), .foregroundColor: Fixture.secondaryText,
            ])
            rows.append(Row(caption: caption, captionRect: CGRect(x: pad + 2, y: y + 2, width: inner - 4, height: Self.captionHeight - 6),
                            pictures: pictures))
            y = top + tallest + (r < table.rows.count - 1 ? Self.rowGap : 0)
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
            HomeCardDraw.text(ctx, row.caption, in: row.captionRect.offsetBy(dx: origin.x, dy: origin.y), alignment: .leading)
            for picture in row.pictures {
                let rect = picture.rect.offsetBy(dx: origin.x, dy: origin.y)
                if let image = picture.slot.image { HomeCardDraw.picture(ctx, image, in: rect) } else { HomeCardDraw.skeleton(ctx, rect) }
                guard !picture.title.isEmpty, rect.width > 2 * Self.pillInset + 24, rect.height > Self.pillHeight + 2 * Self.pillInset else { continue }
                HomeCardDraw.pill(ctx, picture.title,
                                  in: CGRect(x: rect.minX + Self.pillInset, y: rect.maxY - Self.pillInset - Self.pillHeight,
                                             width: rect.width - 2 * Self.pillInset, height: Self.pillHeight),
                                  trailing: false, fill: UIColor(white: 0, alpha: 0.55), text: UIColor(white: 1, alpha: 1))
            }
        }
    }

    func pictureRects(at origin: CGPoint) -> [HomeTableGrid.PictureRect] {
        rows.flatMap { row in
            row.pictures.map { HomeTableGrid.PictureRect(source: $0.slot.source, rect: $0.rect.offsetBy(dx: origin.x, dy: origin.y), loading: $0.slot.loading) }
        }
    }
}
