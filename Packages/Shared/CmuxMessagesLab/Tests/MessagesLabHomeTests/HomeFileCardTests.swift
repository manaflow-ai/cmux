import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// https://github.com/manaflow-ai/cmux/issues/26395: the same .ips file in the Chief chat and in
/// Messages looked different. In cmux it sat in a blue bubble with a generic icon, a name cut at
/// the end and "Document · 127 KB"; Messages shows a neutral card with the file's icon, its name
/// with the extension and the system's kind ("Analytics Report · 127 KB"). The real Home view
/// over the mock owner: I send one .ips file and the Chief sends another. The view is drawn into
/// `.build/home-file-cards.png` (a fleet step returns it with `--artifact`).
@MainActor @Suite(.serialized) struct HomeFileCardTests {
    static let width: CGFloat = 760
    static let mine = AttachmentRef(hash: "hash_ips_mine", name: "cmux DEV-2026-10-28-14-02-11-0001.ips",
                                    mimeType: "application/octet-stream", byteCount: 130_000)
    static let theirs = AttachmentRef(hash: "hash_ips_theirs", name: "FILE_9506.ips", mimeType: "application/octet-stream", byteCount: 130_000)

    func render(_ rig: HomeChatRig) async throws -> CGImage {
        // Row bitmaps draw off main: give them a few frames.
        for _ in 0..<12 {
            rig.frame()
            try await Task.sleep(for: .milliseconds(150))
        }
        let layer = try #require(rig.view.layer)
        let scale: CGFloat = 2
        let size = rig.view.bounds.size
        let ctx = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: scale, y: scale)
        // The view's layers are y-down (a flipped NSView); a bitmap context is y-up.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        return try #require(ctx.makeImage())
    }

    /// Pixels of the outgoing accent (the blue bubble: about 2, 132, 254).
    func accentPixels(_ image: CGImage) throws -> Int {
        let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(ctx.data).bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        var n = 0
        for i in stride(from: 0, to: image.width * image.height * 4, by: 4) where data[i + 2] > 200 && data[i] < 90 && data[i + 1] < 180 { n += 1 }
        return n
    }

    @Test func aFileIsANeutralCardWithItsKindAndExtension() async throws {
        let rig = try await HomeChatRig(history: 0, width: Self.width)
        defer { rig.stop() }
        let empty = try accentPixels(try await render(rig))
        let key = IdempotencyKey("k_file_mine")
        #expect(await rig.source.post([.attachment(Self.mine)], from: rig.me, in: HomeChatRig.conversation, key: key) != nil)
        await HomeChatRig.until { [store = rig.store] in store.transcript(for: HomeChatRig.conversation).contains { $0.key == key && $0.seq != nil } }
        #expect(await rig.post([.attachment(Self.theirs)], key: IdempotencyKey("k_file_theirs")))
        let image = try await render(rig)

        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-file-cards.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))

        // My file is not in the accent bubble: the two cards add no blue (the old 275 x 89.5 pt
        // blue bubble was about 98,000 pixels at 2x).
        let added = try accentPixels(image) - empty
        #expect(added < 500, "the file rows added \(added) accent pixels")

        // What the card draws: the system's kind of an .ips file, the name shortened in the
        // middle with its extension kept, and a card no wider than its text needs.
        let mine = HomeMapping.attachment(Self.mine, picture: nil, progress: nil)
        let theirs = HomeMapping.attachment(Self.theirs, picture: nil, progress: nil)
        #expect(HomeFileCard.isCard(mine))
        #expect(HomeFileCard.detail(theirs) == "Analytics Report \u{00B7} 130 KB")
        let room = HomeFileCard.maxWidth - HomeFileCard.textLeft - HomeFileCard.padRight
        let short = HomeFileCard.truncated(mine.fileName, font: HomeFileCard.nameFont, width: room)
        #expect(short.hasSuffix(".ips") && short.contains("\u{2026}") && short.hasPrefix("cmux DEV-"), "\(short)")
        #expect(TextDraw.width(short, font: HomeFileCard.nameFont) <= room)
        // A long "extension" is not kept whole: the name still fits the card.
        let dump = HomeFileCard.truncated("dump.backup-2026-10-27T15-39-44-full-snapshot", font: HomeFileCard.nameFont, width: room)
        #expect(TextDraw.width(dump, font: HomeFileCard.nameFont) <= room, "\(dump)")
        #expect(HomeFileCard.size(theirs, maxWidth: 600).width < HomeFileCard.maxWidth)
        #expect(HomeFileCard.size(mine, maxWidth: 600).width == HomeFileCard.maxWidth)
        #expect(HomeFileCard.icon(theirs, pixels: 128) != nil)
    }
}
