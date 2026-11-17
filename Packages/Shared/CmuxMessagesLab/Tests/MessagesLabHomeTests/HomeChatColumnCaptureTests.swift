import AppKit
import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The picture of the chat column's layout (the user, 2026-11-09: "fix all alignment issues in imessage chat ui"):
/// a Chief reply in a group as the user's screenshot had it, a text bubble, a Before|After card whose After shots
/// are a little shorter than the Before ones, a line of text and a plain table card, its rows drawn by `RowDraw`
/// over the transcript background at 760 pt, light and dark, in `.build/home-chat-column-light.png` and
/// `-dark.png` (a CI step returns them). It checks only that both drew; `HomeChatColumnTests` checks the edges.
@MainActor @Suite(.serialized) struct HomeChatColumnCaptureTests {
    typealias G = HomeGroupSenderTests
    static let width: CGFloat = 760

    init() {
        HomeMarkdownPolicy.install()
        CustomRows.unregister(HomeTableRowProvider.kind)
        CustomRows.unregister(HomePlanRowProvider.kind)
        HomeTableRowProvider.install()
    }

    static func rows() async throws -> [RowSpec] {
        let f = HomePictureViewerTests.folder()
        let shots: [(String, Int, CGFloat)] = [("bl", 1600, 0.86), ("al", 1440, 0.95), ("bd", 1600, 0.24), ("ad", 1440, 0.16)]
        let pictures = HomeTablePictures()
        for (name, height, gray) in shots {
            let url = f.appendingPathComponent("\(name).png")
            try HomePictureViewerTests.png(at: url, width: 2560, height: height, gray: gray)
            _ = await pictures.prepare(url.path)
        }
        let compare = try HomePictureViewerTests.card(HomePictureViewerTests.beforeAfter(f), media: { pictures.asset($0) })
        let words = HomeTable(header: ["Check", "Result", "Where"], alignments: [.leading, .leading, .leading],
                              rows: [["Compile", "passed", "Blacksmith"], ["Column tests", "9 of 9", "Blacksmith"], ["Fleet capture", "waits", "cmux-lawrence"]],
                              pictures: nil, loading: nil)
        let table = try #require(HomeTableRowProvider.part(words, raw: "raw"))
        var core = ProjectionCore(me: G.me)
        var (conv, _) = core.install(G.id, items: G.items([G.me, G.chief]), summary: G.summary([G.me, G.alice, G.chief]))
        let first = try #require(conv.messages.indices.first), last = try #require(conv.messages.indices.last)
        conv.messages[first].parts = [.text("Show me the sidebar before and after.", runs: [])]
        conv.messages[last].parts = [
            .text("The sidebar rows now share one left edge. Here are the shots.", runs: []),
            .custom(compare),
            .text("And the checks:", runs: []),
            table,
        ]
        return Fixture.withRenderScale(2) {
            RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: G.date(60), width: width, scale: 2)
        }
    }

    func render(_ rows: [RowSpec], light: Bool) -> CGImage? {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let height = rows.reduce(CGFloat(24)) { $0 + $1.total }
        let scale: CGFloat = 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(Self.width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(Fixture.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        var y: CGFloat = 12
        for spec in rows {
            y += spec.gap
            let size = CGSize(width: spec.width, height: spec.height + 2 * RowDraw.margin)
            if let image = Fixture.withRenderScale(2, { WideBitmap.make(size: size, scale: scale, opaque: false) { RowDraw.drawStatic(spec, $0, windowY: .nan) } }) {
                // CG's origin is the bottom left: the row's content top (`margin` into its bitmap) goes `y` under the top.
                let top = y - RowDraw.margin
                ctx.draw(image, in: CGRect(x: 0, y: (height - top - size.height) * scale, width: size.width * scale, height: size.height * scale))
            }
            y += spec.height
        }
        return ctx.makeImage()
    }

    @Test func aChiefReplyWithCardsLightAndDark() async throws {
        let rows = try await Self.rows()
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for light in [true, false] {
            let image = try #require(render(rows, light: light))
            let out = package.appendingPathComponent(".build/home-chat-column-\(light ? "light" : "dark").png")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
    }
}
