import CmuxHomeCore
import CmuxHomeRender
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// A host with fixed snapshots that records clicks and kept keys.
@MainActor
final class FakeWidgets: HomeWidgetHosting {
    var snapshots: [String: HomeWidgetSnapshot] = [:]
    var taps: [(String, String)] = []
    var kept: [ObjectIdentifier: Set<String>] = [:]

    func snapshot(for key: String, widget: ChatWidget) -> HomeWidgetSnapshot? { snapshots[key] }
    func tap(key: String, node: String) { taps.append((key, node)) }
    func keep(_ keys: Set<String>, owner: ObjectIdentifier) { kept[owner] = keys }
    func changes() -> AsyncStream<String> { AsyncStream { _ in } }
}

/// Chat widget bubbles (plans/cmux-next/chat-widgets-DESIGN.md section 4).
@MainActor @Suite(.serialized) struct HomeWidgetRowTests {
    static let card = HomeWidgetSnapshot(items: [
        .text("Widgets in chat", style: .headline),
        .row(node: "pr", title: "o/r #7", subtitle: "Open · octo", symbol: "arrow.triangle.pull", tint: .success),
        .badge("1 failed · 6 passed", tint: .danger),
        .divider,
        .row(node: "c7", title: "check-7", subtitle: "Failed", symbol: "xmark.circle", tint: .danger),
        .text("Page 1 of 2", style: .caption, tint: .secondary),
        .buttons([HomeWidgetButton(node: "prev", title: "Previous", enabled: false),
                  HomeWidgetButton(node: "next", title: "Next", prominent: true)]),
    ])
    static let widget = ChatWidget(app: "cmux/pr-card", propsJSON: #"{"repo":"o/r","number":7}"#,
                                   fallback: "PR #7: Widgets in chat (1 check failed)")

    static func item(_ parts: [MessagePart]) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: ParticipantID("agent_mux"), parts: parts,
                       createdAt: Date(timeIntervalSince1970: 0), delivery: .committed, messageID: MessageID("msg_1"))
    }

    @Test func aWidgetPartIsOneDrawnCardWithTheHostsSnapshot() throws {
        let host = FakeWidgets()
        HomeWidgetRowProvider.install(host)
        let provider = try #require(HomeWidgetRowProvider.installed)
        let key = HomeWidgetRowProvider.key(Self.item([.widget(Self.widget)]), part: 0)
        #expect(key == "msg_1#0")
        provider.store(Self.card, for: key)
        let parts = HomeMapping.projectedParts(Self.item([.text("Here is the PR."), .widget(Self.widget)]), summary: nil).parts
        guard case .custom(let custom)? = parts.last else {
            Issue.record("the widget is no custom row: \(parts)")
            return
        }
        let payload = try #require(HomeWidgetRowProvider.payload(custom))
        #expect(payload.key == "msg_1#1")
        // The snapshot was stored for #0: this part has none yet and draws its fallback.
        #expect(payload.snapshot == nil)
        #expect(provider.plainText(custom) == Self.widget.fallback)
    }

    @Test func aCardIsTallerThanItsFallbackAndGrowsWithItsRows() throws {
        let provider = HomeWidgetRowProvider(host: nil)
        let card = try #require(customPart(Self.card))
        let fallback = try #require(customPart(nil))
        let cardSize = provider.measure(card, maxWidth: 400)
        let fallbackSize = provider.measure(fallback, maxWidth: 400)
        #expect(cardSize.width == HomeWidgetLayout.maxWidth)
        #expect(cardSize.height > fallbackSize.height)
        var longer = Self.card
        longer.items.insert(.row(node: "c1", title: "check-1", subtitle: "Passed", symbol: "checkmark.circle", tint: .success), at: 5)
        let longerSize = provider.measure(try #require(customPart(longer)), maxWidth: 400)
        #expect(longerSize.height == cardSize.height + HomeWidgetLayout.rowHeight + HomeWidgetLayout.spacing)
    }

    @Test func aClickOnARowOrAnEnabledButtonGoesToItsNode() throws {
        let host = FakeWidgets()
        let provider = HomeWidgetRowProvider(host: host)
        let part = try #require(customPart(Self.card))
        let layout = HomeWidgetLayout(Self.card, width: 400)
        let buttons = try #require(layout.placed.last?.buttons)
        let row = try #require(layout.placed.first { if case .row(let node, _, _, _, _, _) = $0.item { node == "pr" } else { false } })
        let ref = MessagesLabHome.PartRef(messageId: "msg_1", partIndex: 0)
        #expect(provider.tapped(part, ref: ref, at: CGPoint(x: row.frame.midX, y: row.frame.midY), width: 400))
        #expect(provider.tapped(part, ref: ref, at: CGPoint(x: buttons[1].frame.midX, y: buttons[1].frame.midY), width: 400))
        // Previous is disabled; the badge takes no click.
        #expect(!provider.tapped(part, ref: ref, at: CGPoint(x: buttons[0].frame.midX, y: buttons[0].frame.midY), width: 400))
        #expect(host.taps.map(\.1) == ["pr", "next"])
        #expect(host.taps.allSatisfy { $0.0 == "msg_1#0" })
    }

    @Test(arguments: [true, false]) func aCardDrawsInLightAndDark(light: Bool) throws {
        let saved = Fixture.lightAppearance
        defer { Fixture.lightAppearance = saved }
        Fixture.lightAppearance = light
        let provider = HomeWidgetRowProvider(host: nil)
        let part = try #require(customPart(Self.card))
        let size = provider.measure(part, maxWidth: 400)
        let scale = 2
        let ctx = try #require(CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        provider.drawRow(part, in: ctx, rect: CGRect(origin: .zero, size: size),
                         context: CustomRowDrawContext(outgoing: false, isDark: !light, elevated: false))
        let image = try #require(ctx.makeImage())
        #expect(Self.inkedPixels(image) > 500)
        if let dir = ProcessInfo.processInfo.environment["CMUX_WIDGET_SHOTS"] {
            try Self.png(image, to: URL(fileURLWithPath: dir).appendingPathComponent("pr-card-\(light ? "light" : "dark").png"))
        }
    }

    private func customPart(_ snapshot: HomeWidgetSnapshot?) -> CustomPart? {
        guard case .custom(let part)? = HomeWidgetRowProvider.custom(.init(key: "msg_1#0", fallback: Self.widget.fallback, snapshot: snapshot))
        else { return nil }
        return part
    }

    static func inkedPixels(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var count = 0
        for i in stride(from: 3, to: CFDataGetLength(data), by: 4) where bytes[i] > 0 { count += 1 }
        return count
    }

    static func png(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
