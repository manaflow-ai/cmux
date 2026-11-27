import AppKit
@testable import CmuxHomeCore
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// Two Home chats on screen at once (the Chief pane and a chat with its own Chat Colors…) each draw
/// with their own bubble colours (user 2026-10-28: per-chat colours). The vendored renderer kept one
/// palette for the app (`Fixture.theme`): the view that applied its theme last repainted the other's
/// rows, so a yellow chat drew blue bubbles or white text on yellow. Each view's pixels are checked
/// after the other applied its palette.
@MainActor @Suite(.serialized) struct HomeChatColorsTwoViewsTests {
    static let dark = HomePalette.Theme(background: .gray255(30), foreground: .gray255(230),
                                        accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58))
    static let yellow = HomeColor.rgb255(255, 214, 10), navy = HomeColor.rgb255(28, 42, 74)
    static let blue = HomeColor.rgb255(2, 132, 254)

    /// The view's layer drawn into an sRGB bitmap at 2x (as HomeReplyQuoteCaptureTests draws it).
    private func render(_ rig: HomeChatRig) throws -> CGImage {
        let layer = try #require(rig.view.layer)
        let size = rig.view.bounds.size
        let ctx = try #require(CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        return try #require(ctx.makeImage())
    }

    /// How many pixels are within 24 (of 255) per channel of `color`.
    private func count(_ color: HomeColor, in image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let r = Int(color.red * 255), g = Int(color.green * 255), b = Int(color.blue * 255)
        var n = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let o = y * image.bytesPerRow + x * 4
                if abs(Int(bytes[o]) - r) < 24, abs(Int(bytes[o + 1]) - g) < 24, abs(Int(bytes[o + 2]) - b) < 24 { n += 1 }
            }
        }
        return n
    }

    /// The image's six most common colours (quantized to 16 levels), for a failure's message.
    private func top(_ image: CGImage) -> String {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return "no data" }
        var counts: [Int: Int] = [:]
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let o = y * image.bytesPerRow + x * 4
                counts[(Int(bytes[o]) / 16) << 8 | (Int(bytes[o + 1]) / 16) << 4 | Int(bytes[o + 2]) / 16, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(6)
            .map { String(format: "#%X%X%X×%d", $0.key >> 8, ($0.key >> 4) & 15, $0.key & 15, $0.value) }.joined(separator: " ")
    }

    private func post(_ rig: HomeChatRig, _ id: String, author: ParticipantID, _ text: String) throws {
        let conversation = HomeChatRig.conversation
        let summary = try #require(rig.store.summary(conversation))
        let rev = rig.store.mirror.revision(of: .conversation(conversation)) + 1
        rig.store.handle(.message(CmuxHomeCore.Message(id: MessageID(id), conversation: conversation, seq: summary.lastSeq + 1,
                                                       clientMessageID: IdempotencyKey(id), author: author, parts: [.text(HomeChatRig.tag + text)],
                                                       createdAt: Date()), rev: rev))
    }

    private func settle(_ rigs: [HomeChatRig]) async throws {
        // Row bitmaps draw off main: give them a few frames.
        for _ in 0..<12 {
            rigs.forEach { $0.frame() }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    @Test func twoChatsKeepTheirOwnBubbleColors() async throws {
        let colored = try await HomeChatRig(history: 0, width: 628)
        defer { colored.stop() }
        let plain = try await HomeChatRig(history: 0, width: 628)
        defer { plain.stop() }
        for rig in [colored, plain] {
            try post(rig, "msg_mine", author: rig.me, "What is blocking the iOS archive? It has been a while now.")
            try post(rig, "msg_theirs", author: rig.chief, "Two tests failed on the base branch; they are not ours.")
        }
        let base = HomePalette.iMessageStyled(Self.dark)
        colored.view.applyTheme(active: base.applying(HomeBubbleColors(sent: Self.yellow, received: Self.navy)))
        // The second view applies its palette last, as the Chief pane does after a chat with colours.
        plain.view.applyTheme(active: base, measuredAccent: true)
        try await settle([colored, plain])

        let coloredImage = try render(colored), plainImage = try render(plain)
        let seen = "colored: \(colored.bubbles().count) bubbles, \(top(coloredImage)); plain: \(plain.bubbles().count) bubbles, \(top(plainImage))"
        #expect(count(Self.yellow, in: coloredImage) > 400, "the chat with colours draws its yellow bubbles; \(seen)")
        #expect(count(Self.navy, in: coloredImage) > 400, "the chat with colours draws its navy bubbles")
        #expect(count(Self.yellow, in: plainImage) < 20, "the plain chat draws no yellow")
        #expect(count(Self.blue, in: plainImage) > 400, "the plain chat keeps Messages' blue; \(seen)")
        // Black text on yellow: dark pixels inside the yellow bubble, not white ones.
        #expect(count(.gray255(255), in: coloredImage) < count(.gray255(255), in: plainImage),
                "no white text on the yellow bubble")
    }
}
