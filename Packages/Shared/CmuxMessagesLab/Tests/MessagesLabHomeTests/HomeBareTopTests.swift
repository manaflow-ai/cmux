import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Home's chat with no header (Leo 2026-10-21: "why is there a top banner? ... iMessage dissipates
/// that, and we don't even need this in the first place"): no avatar, no "Chief >" pill and no band
/// over the transcript. The oldest row rests just under the pane's top, and the rows fade out over
/// the top few points as they scroll away, so nothing ever covers their text.
///
/// The test reads the pane's views and the alpha the transcript clip's mask gives the rows (the
/// mask rendered on its own); the fade itself only draws on screen (the media tour's Home captures).
@MainActor @Suite(.serialized) struct HomeBareTopTests {
    /// The rows' alpha at each pane y (top-down): the transcript clip's mask, rendered in the clip's
    /// coordinates (the mask starts above the clip's top).
    private static func rowAlpha(_ demo: MessagesWindowView, at ys: [CGFloat]) throws -> [CGFloat] {
        let mask = try #require(demo.clip.layer.mask)
        let size = demo.clip.bounds.size
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: mask.frame.minX, y: mask.frame.minY)
        mask.render(in: ctx)
        let data = try #require(ctx.data)
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return ys.map { y in
            let row = min(h - 1, max(0, Int(y)))
            return CGFloat(px[row * w * 4 + (w / 2) * 4 + 3]) / 255
        }
    }

    @Test func theChatHasNoHeaderAndItsRowsFadeOutAtTheTop() async throws {
        let rig = try await HomeChatRig(history: 300, width: 620)
        defer { rig.stop() }
        let view = rig.view
        // Home's default, as HomeNativeTranscriptView sets it.
        view.setBareTop()
        let host = view.controller.host
        host.paneHeader.title = "Chief"
        rig.window.contentView?.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let demo = try #require(view.controller.demo)

        // No header: no avatar, no name pill, no glass band, no blurred backdrop.
        #expect(host.paneHeader.bare)
        #expect(host.paneHeader.avatar.isHidden && host.paneHeader.pill.isHidden)
        #expect(view.headerGlass == nil)
        #expect(host.headerBackdrop.isHidden)
        #expect(view.headerHeight == HostView.bareTopInset)
        // The rows near the top keep their clicks and scrolls: the scroll view reaches the top and
        // the bare header takes nothing.
        #expect(host.scrollView.frame.minY == 0)
        let nearTop = host.convert(NSPoint(x: host.bounds.midX, y: 30), to: host.superview)
        #expect(host.paneHeader.hitTest(nearTop) == nil)
        #expect(host.hitTest(nearTop) !== host.paneHeader)

        // Scrolled to the oldest loaded row, it rests just under the pane's top.
        #expect(demo.minOffset < demo.pinnedOffset, "the history fits: nothing to scroll")
        demo.collection.contentOffset = CGPoint(x: demo.collection.contentOffset.x, y: demo.minOffset)
        demo.userScrolled()
        #expect(demo.rowsTopInset == HostView.bareTopInset)
        // The offset snaps to device pixels: within half a point.
        #expect(abs(demo.windowY(contentY: demo.layout.rowsTop) - HostView.bareTopInset) <= 0.5)
        #expect(demo.visibleTop == HostView.bareTopInset - 8)

        // The fade: nothing at the very top, about half way through it, full strength from its end down.
        let fade = HostView.bareTopInset
        let ys = [1, fade / 2, fade, fade + 8, host.bounds.height / 2]
        let alpha = try Self.rowAlpha(demo, at: ys)
        #expect(alpha[0] < 0.2, "rows at the top edge draw at \(alpha[0])")
        #expect(alpha[1] > 0.3 && alpha[1] < 0.7, "the fade's middle is \(alpha[1])")
        #expect(alpha[2...].allSatisfy { $0 >= 0.98 }, "rows below the fade are dimmed: \(zip(ys, alpha).map { "\($0): \($1)" })")
    }

    /// The top-right panel toggles (#22702) stay with no header: at the pane's top right, taking their
    /// own clicks, the rest of the top passing clicks to the rows, which rest under the toggles.
    @Test func theTopRightTogglesStayWithNoHeader() async throws {
        let rig = try await HomeChatRig(history: 300, width: 620)
        defer { rig.stop() }
        let view = rig.view
        view.setBareTop()
        let host = view.controller.host
        host.paneHeader.title = "Chief"
        let toggles = HomeHeaderTrailingAccessoryTests.TwoButtons(frame: .zero)
        view.headerTrailingAccessory = toggles
        rig.window.contentView?.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        toggles.layoutSubtreeIfNeeded()
        let demo = try #require(view.controller.demo)

        #expect(!toggles.isHidden)
        #expect(toggles.frame.minY == PaneHeaderView.bareAccessoryTop)
        #expect(toggles.frame.maxX == host.bounds.width - PaneHeaderView.trailingInset)
        let header = host.paneHeader
        let onRight = header.convert(NSPoint(x: toggles.frame.minX + toggles.right.frame.midX, y: toggles.frame.midY), to: header.superview)
        #expect(header.hitTest(onRight) === toggles.right)
        let middle = header.convert(NSPoint(x: header.bounds.midX, y: toggles.frame.midY), to: header.superview)
        #expect(header.hitTest(middle) == nil)

        let rowsTop = PaneHeaderView.bareAccessoryTop + 28 + 8
        #expect(host.bareRowsTop == rowsTop)
        #expect(view.headerHeight == rowsTop)
        #expect(demo.rowsTopInset == rowsTop)
        #expect(demo.topFade == rowsTop)
    }

    /// Debug Settings > Home > Avatar and name over the chat: the header pane keeps Messages' geometry
    /// (the rows 8 pt under the 80 pt header, no fade).
    @Test func theHeaderPaneKeepsMessagesGeometry() async throws {
        let rig = try await HomeChatRig(history: 40, width: 620)
        defer { rig.stop() }
        rig.view.setHeaderGlass()
        rig.window.contentView?.layoutSubtreeIfNeeded()
        let demo = try #require(rig.view.controller.demo)
        #expect(!rig.view.controller.host.bareTop)
        #expect(demo.rowsTopInset == Fixture.headerHeight + 8)
        #expect(demo.topFade == 0)
        #expect(demo.clipMask.colors == nil)
        #expect(rig.view.headerHeight == Fixture.headerHeight)
    }
}
