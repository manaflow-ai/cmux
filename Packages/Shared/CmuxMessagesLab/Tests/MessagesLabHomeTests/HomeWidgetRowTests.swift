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
        let look = light ? "light" : "dark"
        // Before: the fallback text bubble (no host, or the app is missing). After: the card.
        for (name, snapshot) in [("before", nil), ("after", Self.card)] as [(String, HomeWidgetSnapshot?)] {
            let part = try #require(customPart(snapshot))
            let image = try #require(Self.render(provider, part, light: light))
            #expect(Self.inkedPixels(image) > 500)
            try Self.png(image, to: Self.shots.appendingPathComponent("pr-card-\(name)-\(look).png"))
        }
    }

    /// Where the Before|After shots go: `CMUX_WIDGET_SHOTS`, else the package's `.build/widget-shots`
    /// (a fleet step returns them with `--artifact`).
    static var shots: URL {
        if let dir = ProcessInfo.processInfo.environment["CMUX_WIDGET_SHOTS"] { return URL(fileURLWithPath: dir) }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return package.appendingPathComponent(".build/widget-shots")
    }

    /// The row as the transcript draws it: the incoming bubble, then the provider's body, at 2x.
    static func render(_ provider: HomeWidgetRowProvider, _ part: CustomPart, light: Bool) -> CGImage? {
        let size = provider.measure(part, maxWidth: 400)
        let pad: CGFloat = 16, scale: CGFloat = 2
        let canvas = CGSize(width: size.width + 2 * pad, height: size.height + 2 * pad)
        guard let ctx = CGContext(data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setFillColor(Fixture.background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: canvas))
        let body = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        ctx.setFillColor(Fixture.incoming.cgColor)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: Fixture.bubbleRadius, cornerHeight: Fixture.bubbleRadius, transform: nil))
        ctx.fillPath()
        provider.drawRow(part, in: ctx, rect: body, context: CustomRowDrawContext(outgoing: false, isDark: !light, elevated: false))
        return ctx.makeImage()
    }

    private func customPart(_ snapshot: HomeWidgetSnapshot?) -> CustomPart? {
        guard case .custom(let part)? = HomeWidgetRowProvider.custom(.init(key: "msg_1#0", fallback: Self.widget.fallback, snapshot: snapshot))
        else { return nil }
        return part
    }

    /// Pixels that differ from the canvas corner (the background): the bubble and what is drawn on it.
    static func inkedPixels(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var count = 0
        for i in stride(from: 0, to: CFDataGetLength(data) - 3, by: 4)
        where abs(Int(bytes[i]) - Int(bytes[0])) + abs(Int(bytes[i + 1]) - Int(bytes[1])) + abs(Int(bytes[i + 2]) - Int(bytes[2])) > 24 {
            count += 1
        }
        return count
    }

    static func png(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
