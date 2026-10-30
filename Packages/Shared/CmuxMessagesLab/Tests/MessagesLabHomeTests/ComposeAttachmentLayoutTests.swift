import AppKit
import Testing
@testable import MessagesLabHome

/// Pasted pictures in the Home composer are small thumbnails in a row (user
/// report 2026-10-18: two pasted screenshots stacked as 118 pt blocks made the
/// field ~280 pt tall and pushed the text to the bottom).
@MainActor @Suite struct ComposeAttachmentLayoutTests {
    private func image(_ id: String, _ w: Int, _ h: Int) -> MessagesLabHome.Attachment {
        MessagesLabHome.Attachment(id: id, kind: "image", fileName: "\(id).png", mimeType: "image/png", byteSize: 1,
                   asset: "/tmp/\(id).png", poster: nil, width: w, height: h, durationSeconds: nil, transfer: .done)
    }

    private func file(_ id: String) -> MessagesLabHome.Attachment {
        MessagesLabHome.Attachment(id: id, kind: "file", fileName: "\(id).pdf", mimeType: "application/pdf", byteSize: 7000,
                   asset: "/tmp/\(id).pdf", poster: nil, width: nil, height: nil, durationSeconds: nil, transfer: .done)
    }

    @Test func twoScreenshotsSitInOneShortRow() {
        // The two screenshots of the report, 528 x 568 px and 1412 x 1106 px at 2x.
        let (tiles, height) = ComposeAttachmentStrip.layout([image("a", 528, 568), image("b", 1412, 1106)], width: 600, scale: 2)
        #expect(tiles.count == 2)
        #expect(tiles[0].rect.minY == tiles[1].rect.minY)
        #expect(tiles[1].rect.minX > tiles[0].rect.maxX)
        for t in tiles { #expect(t.rect.height <= ComposeAttachmentStrip.imageMaxHeight + 0.5) }
        #expect(height <= ComposeAttachmentStrip.imageMaxHeight + ComposeAttachmentStrip.gap + 0.5)
    }

    @Test func thumbnailsKeepTheImageAspect() throws {
        let (tiles, _) = ComposeAttachmentStrip.layout([image("a", 1412, 1106)], width: 600, scale: 2)
        let r = try #require(tiles.first).rect
        #expect(abs(r.width / r.height - 1412.0 / 1106.0) < 0.05)
    }

    @Test func aFullRowWrapsAndTheStripGrowsByOneRow() {
        let atts = (0..<8).map { image("i\($0)", 256, 128) }   // 128 x 64 pt each
        let (tiles, height) = ComposeAttachmentStrip.layout(atts, width: 400, scale: 2)
        let rows = Set(tiles.map { $0.rect.minY }).count
        #expect(rows > 1)
        for t in tiles { #expect(t.rect.maxX <= 400) }
        let row = ComposeAttachmentStrip.imageMaxHeight + ComposeAttachmentStrip.gap
        #expect(abs(height - CGFloat(rows) * row) < 1)
    }

    @Test func filesArePillsInTheSameRow() {
        let (tiles, height) = ComposeAttachmentStrip.layout([file("f"), image("a", 256, 128)], width: 600, scale: 2)
        #expect(tiles[0].rect.height == ComposeAttachmentStrip.fileHeight)
        #expect(tiles[0].rect.minY == tiles[1].rect.minY)
        #expect(height <= ComposeAttachmentStrip.imageMaxHeight + ComposeAttachmentStrip.gap + 0.5)
    }

    @Test func noAttachmentsAddNoHeight() {
        #expect(ComposeAttachmentStrip.layout([], width: 600, scale: 2).height == 0)
    }

    /// A file pill's type icon is looked up once per type (a second pill of the type reuses it).
    @Test func filePillIconsAreLookedUpOncePerType() {
        let first = ComposeInlineAttachmentView.icon(forMimeType: "application/pdf")
        let second = ComposeInlineAttachmentView.icon(forMimeType: "application/pdf")
        #expect(first === second)
    }
}
