import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The round "C" Chief avatar and its "Chief >" label never sit on readable message text
/// (u2891 and the width sweep, 2026-10-19: "Started three agents o…" under the avatar).
///
/// Home's header has no band while the pointer is away from it (HeaderFade.swift, Lawrence
/// 2026-10-08), and the rows are drawn under the header (R76), so a scrolled transcript showed
/// sharp text under the avatar and the label. The rule: the rows show at alpha 0 behind the
/// avatar and the label, and at full alpha where the oldest message rests at the top of the
/// transcript (8 pt under the header, `MessagesWindowView.minOffset`). The test reads the alpha
/// the pane gives the rows, rendered from the rows' own mask.
@MainActor @Suite(.serialized) struct HomeHeaderCoversNoTextTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    /// The alpha of the rows at each pane y (top-down), as the render server composites them:
    /// the rows' host layer's mask rendered on its own (1 when there is no mask).
    private static func rowAlpha(_ host: HostView, at ys: [CGFloat]) -> [CGFloat] {
        guard let mask = host.below.root.mask else { return ys.map { _ in 1 } }
        let size = host.below.bounds.size
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return ys.map { _ in 1 } }
        // Top-down, as the flipped pane.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -mask.frame.minX, y: -mask.frame.minY)
        mask.render(in: ctx)
        guard let data = ctx.data else { return ys.map { _ in 1 } }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return ys.map { y in
            let row = min(h - 1, max(0, Int(y)))
            return CGFloat(px[row * w * 4 + (w / 2) * 4 + 3]) / 255
        }
    }

    @Test func theAvatarAndItsLabelCoverNoMessageText() async throws {
        let options = MockHomeSource.Options(chiefHistory: 300, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        defer { store.stop() }
        let conversation = ConversationID("conv_chief")
        await until { store.me != nil && store.isOnline }
        await store.open(conversation)
        await until { !store.transcript(for: conversation).isEmpty }
        let me = try #require(store.me?.id)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MessagesLabHomeView(store: store, conversation: conversation, me: me, wake: NoWake())
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
        window.contentView = view
        // Home's header, as HomeNativeTranscriptView sets it.
        view.setHeaderFade(color: .black, maxAlpha: 0.5) { _ in 0 }
        view.projection.refresh()
        window.contentView?.layoutSubtreeIfNeeded()

        let host = view.controller.host
        host.paneHeader.title = "Chief"
        host.paneHeader.layoutSubtreeIfNeeded()
        let avatar = host.paneHeader.avatar.frame, pill = host.paneHeader.pill.frame
        #expect(!host.paneHeader.avatar.isHidden && avatar.height > 0, "no avatar to check")

        // Scrolled to the bottom (where a transcript opens): message rows sit under the avatar and the label.
        let demo = try #require(host.demo)
        let n = demo.model.rows.count
        let under = (0..<max(0, n - 1)).contains { i in
            let top = demo.windowY(contentY: demo.layout.contentTop(i)), bottom = demo.windowY(contentY: demo.layout.contentTop(i + 1))
            return top < pill.maxY && bottom > avatar.minY
        }
        #expect(under, "no message row under the header at the bottom of the transcript: nothing to cover")

        // Behind the avatar and the label: the rows must not show.
        let covered = [avatar.minY + 1, avatar.midY, avatar.maxY - 1, pill.minY + 1, pill.midY, pill.maxY - 1]
        let underControls = Self.rowAlpha(host, at: covered)
        #expect(underControls.allSatisfy { $0 <= 0.02 }, "rows show under the avatar or label at alpha \(underControls)")

        // Where the oldest message rests at the top (8 pt under the header) and below it: full alpha.
        let resting = [Fixture.headerHeight + 8, Fixture.headerHeight + 40, host.bounds.height / 2]
        let shown = Self.rowAlpha(host, at: resting)
        #expect(shown.allSatisfy { $0 >= 0.98 }, "the first message at the top is faded: alpha \(shown)")
    }
}
