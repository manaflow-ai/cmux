import AppKit
@testable import CmuxHomeCore
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// a1305's dark shots at 25419cd: after a light to dark switch, the Chief's large welcome message (the
/// Markdown shortcut list) stayed a light grey bubble with dark text, while the smaller bubbles around it turned
/// dark. A theme switch redrew every row twice: `setLightAppearance` redrew them in the view's old palette (the
/// light one, under the new appearance), then `setPalette` and a second pass redrew them in the dark one. The
/// row bitmaps draw off main, a newer request lowers the priority of the older ones, and a cell took any bitmap of
/// its row whatever palette it was drawn in: the slow welcome row's light bitmap landed last and stayed.
@MainActor @Suite(.serialized) struct HomeDarkSwitchBubbleTests {
    static let light = HomePalette.Theme(background: .gray255(255), foreground: .gray255(20),
                                         accent: .rgb255(0, 122, 255), failure: .rgb255(255, 59, 48))
    static let dark = HomePalette.Theme(background: .gray255(30), foreground: .gray255(230),
                                        accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58))
    /// The welcome's shape (ChiefWelcome): a line about the Chief, then the shortcut list.
    static let welcome = """
        I run cmux for you. Ask me to send off agents, watch your workspaces, change settings or set your background.

        How to use cmux:
        - `⌘N` New Workspace
        - `⌘T` New Tab
        - `⌘D` Split Right
        - `⇧⌘D` Split Down
        - `⌘L` Focus Location Bar
        - `⇧⌘L` New Browser Tab
        - `⌘P` Go to Workspace
        - `⇧⌘P` Command Palette
        """

    /// The view's layer drawn into an sRGB bitmap at 2x (as HomeChatColorsTwoViewsTests draws it).
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

    /// How many pixels are within 6 (of 255) per channel of `color` (the dark text, 225, is 8 from the light grey, 233).
    private func count(_ color: HomeColor, in image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let r = Int(color.red * 255), g = Int(color.green * 255), b = Int(color.blue * 255)
        var n = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let o = y * image.bytesPerRow + x * 4
                if abs(Int(bytes[o]) - r) < 6, abs(Int(bytes[o + 1]) - g) < 6, abs(Int(bytes[o + 2]) - b) < 6 { n += 1 }
            }
        }
        return n
    }

    private func post(_ rig: HomeChatRig, _ id: String, _ text: String) throws {
        let conversation = HomeChatRig.conversation
        let summary = try #require(rig.store.summary(conversation))
        let rev = rig.store.mirror.revision(of: .conversation(conversation)) + 1
        rig.store.handle(.message(CmuxHomeCore.Message(id: MessageID(id), conversation: conversation, seq: summary.lastSeq + 1,
                                                       clientMessageID: IdempotencyKey(id), author: rig.chief, parts: [.text(HomeChatRig.tag + text)],
                                                       createdAt: Date()), rev: rev))
    }

    private func settle(_ rig: HomeChatRig) async throws {
        // Row bitmaps draw off main: give them a few frames (as HomeChatColorsTwoViewsTests does).
        for _ in 0..<12 {
            rig.frame()
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Light, then dark: every bubble is dark, whatever order the off-main bitmaps land in. The test holds the
    /// switch's bitmaps and lets the ones drawn in another palette than the dark one land last (the order a
    /// lowered priority gives a slow row).
    @Test func aDarkSwitchLeavesNoLightBubble() async throws {
        let rig = try await HomeChatRig(history: 0, width: 700)
        defer { rig.stop() }
        try post(rig, "msg_hello", "Welcome to cmux! I'm Chief.")
        try post(rig, "msg_welcome", Self.welcome)
        try post(rig, "msg_after", "Want to make it yours? Pick a background, or skip it and just say hi.")
        let lightPalette = HomePalette.iMessageStyled(Self.light), darkPalette = HomePalette.iMessageStyled(Self.dark)
        rig.view.applyTheme(active: lightPalette)
        try await settle(rig)
        let before = try render(rig)
        #expect(count(lightPalette.incomingBubble, in: before) > 20_000, "the light bubbles did not draw; the test shows nothing")

        RowBitmaps.testHold = true
        defer {
            RowBitmaps.testHold = false
            RowBitmaps.shared.releaseHeld()
        }
        rig.view.applyTheme(active: darkPalette)
        try await settle(rig)
        let darkGeneration = Fixture.generation(of: PaletteScope.box(for: FixtureTheme(active: darkPalette)))
        RowBitmaps.shared.held.sort { $0.0.palette == darkGeneration && $1.0.palette != darkGeneration }
        RowBitmaps.testHold = false
        RowBitmaps.shared.releaseHeld()
        try await settle(rig)

        let after = try render(rig)
        let lightPixels = count(lightPalette.incomingBubble, in: after), darkPixels = count(darkPalette.incomingBubble, in: after)
        #expect(darkPixels > 20_000, "the dark bubbles did not draw (\(darkPixels) dark, \(lightPixels) light pixels)")
        #expect(lightPixels < 20_000, "a bubble stayed light after the switch to dark: \(lightPixels) light grey pixels")
    }
}
