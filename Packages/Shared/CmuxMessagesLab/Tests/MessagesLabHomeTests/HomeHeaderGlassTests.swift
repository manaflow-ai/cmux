import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Home's header as Messages draws it on macOS 26 (Lawrence 2026-10-20: "chief fade is not liquid
/// glassy enough and covers too much stuff"): a thin glass band, only as tall as the Chief's avatar
/// and its "Chief >" pill plus a short soft edge, over the transcript. The rows scroll under it at
/// full strength (the glass blurs them), never masked out or dimmed by a dark fade below the
/// header, and the pill is glass with no dark capsule behind it.
///
/// The test reads the pane's views and the alpha the pane gives the rows (the rows' own mask,
/// rendered); the glass's blur itself only draws on screen (the media tour's Home captures).
@MainActor @Suite(.serialized) struct HomeHeaderGlassTests {
    /// The alpha of the rows at each pane y (top-down): the rows' host layer's mask rendered on its
    /// own (1 when there is no mask).
    private static func rowAlpha(_ host: HostView, at ys: [CGFloat]) -> [CGFloat] {
        guard let mask = host.below.root.mask else { return ys.map { _ in 1 } }
        let size = host.below.bounds.size
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return ys.map { _ in 1 } }
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

    @Test(arguments: [false, true])
    func theHeaderIsAThinGlassBandOverLegibleRows(light: Bool) async throws {
        let rig = try await HomeChatRig(history: 300, width: 620)
        defer { rig.stop() }
        let view = rig.view
        rig.window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        // Home's header, as HomeNativeTranscriptView sets it.
        view.setHeaderGlass()
        rig.window.contentView?.layoutSubtreeIfNeeded()
        let host = view.controller.host
        host.paneHeader.title = "Chief"
        host.paneHeader.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let avatar = host.paneHeader.avatar.frame, pill = host.paneHeader.pill.frame

        // The band: glass (system glass on macOS 26, a visual-effect view before), the pane's
        // full width, from the top, covering the avatar and the pill and ending a short soft edge
        // under the pill.
        let glass = try #require(view.headerGlass, "no glass band over the header")
        if #available(macOS 26, *) {
            #expect(glass.surface is NSGlassEffectView, "macOS 26: the band is system Liquid Glass")
        } else {
            #expect(glass.surface is NSVisualEffectView, "before macOS 26: the band is a visual-effect view")
        }
        #expect(!glass.isHidden && glass.superview === host)
        #expect(glass.frame.minY == 0 && glass.frame.width == host.bounds.width)
        #expect(glass.frame.maxY >= pill.maxY && glass.frame.maxY >= avatar.maxY, "the band covers the avatar and the pill")
        #expect(glass.frame.maxY <= pill.maxY + 16, "the band is \(glass.frame.maxY) pt tall: taller than the avatar and the pill")
        // Over the controls' header, under the controls themselves.
        let order = host.subviews
        #expect((order.firstIndex(of: glass) ?? .max) < (order.firstIndex(of: host.paneHeader) ?? -1))
        #expect((order.firstIndex(of: glass) ?? -1) > (order.firstIndex(of: host.below) ?? .max))
        // The glass takes no clicks or scrolls: the transcript under its soft edge keeps them.
        let underEdge = NSPoint(x: host.bounds.midX, y: glass.frame.maxY - 2)
        #expect(glass.hitTest(host.convert(underEdge, to: glass.superview)) == nil)

        // No dark fade: the old blurred band and its hover fade are gone.
        #expect(host.headerBackdrop.isHidden, "the old header band still draws")

        // The rows scroll under the glass at full strength, never masked out or dimmed below it.
        let ys = [avatar.midY, pill.midY, glass.frame.maxY, glass.frame.maxY + 8, Fixture.headerHeight + 8, host.bounds.height / 2]
        let alpha = Self.rowAlpha(host, at: ys)
        #expect(alpha.allSatisfy { $0 >= 0.98 }, "rows are masked or dimmed at \(zip(ys, alpha).map { "\($0): \($1)" })")

        // The pill is glass with no dark capsule behind it.
        let backing = host.paneHeader.pillBacking.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }?.alphaComponent ?? 0
        #expect(backing == 0, "a dark capsule (alpha \(backing)) sits behind the name pill")
        if #available(macOS 26, *) {
            #expect(host.paneHeader.pill.bezelStyle == .glass)
        } else {
            #expect(host.paneHeader.pillGlass is NSVisualEffectView, "before macOS 26: the pill sits on a visual-effect capsule")
        }
    }
}
