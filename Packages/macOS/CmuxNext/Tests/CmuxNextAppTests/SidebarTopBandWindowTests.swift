import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar

/// Coordinator report 2026-10-03 (appslbl-v1): in a real window the sidebar's
/// top band (Home, App Store, CodeRouter) drew blank and a click on its
/// first row did nothing, while the bottom band and the workspace rows drew.
/// The top band's rows must be laid out inside the visible band, be the hit
/// target under the pointer, and run their item when clicked.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct SidebarTopBandWindowTests {
    @Test func theTopBandRowsAreVisibleAndHitInAWindow() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let sidebar = harness.window.sidebar.container.sidebarView
        let window = try #require(sidebar.window)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<20 { await Task.yield() }
        window.contentView?.layoutSubtreeIfNeeded()
        let region = sidebar.aboveRegion
        let scroll = try #require(region.enclosingScrollView)
        var report = ["sidebar \(sidebar.frame) band \(scroll.superview?.frame ?? .zero) clip \(scroll.contentView.bounds)",
                      "region \(region.frame) height \(region.layoutResult.height) hidden \(region.isHiddenOrHasHiddenAncestor)",
                      "items \(sidebar.model.itemInfo.keys.map(\.rawValue).sorted())"]
        for id in ["itm_home", "itm_app_store", "itm_app_coderouter"] {
            let row = region.itemView(LayoutItemID(id))
            report.append("\(id): row \(row.map { "\($0.frame) title \($0.info.title) alpha \($0.alphaValue)" } ?? "none")")
        }
        let summary = report.joined(separator: "\n")
        let home = try #require(region.itemView(LayoutItemID("itm_home")), "\(summary)")
        #expect(!home.isHiddenOrHasHiddenAncestor, "\(summary)")
        let visible = region.convert(scroll.contentView.bounds, from: scroll.contentView)
        #expect(visible.intersects(home.frame), "Home is outside the band's visible rect\n\(summary)")
        let center = home.convert(NSPoint(x: home.bounds.midX, y: home.bounds.midY), to: nil)
        let hit = window.contentView?.hitTest(window.contentView!.convert(center, from: nil))
        #expect(hit === home || hit === region || hit?.isDescendant(of: region) == true, "hit \(String(describing: hit))\n\(summary)")

        // What debug.window_snapshot renders: the Home row must show ink
        // (its title) like the Settings row in the bottom band does.
        let rep = try #require(window.renderSnapshot())
        if let dir = ProcessInfo.processInfo.environment["NX_ARTIFACTS"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/top-band.png"))
        }
        let settings = try #require(sidebar.belowRegion.itemView(LayoutItemID("itm_settings")))
        let homeInk = Self.inkFraction(rep, rect: home.convert(home.bounds, to: nil), window: window)
        let settingsInk = Self.inkFraction(rep, rect: settings.convert(settings.bounds, to: nil), window: window)
        #expect(homeInk > 0.01, "Home row renders blank (ink \(homeInk), Settings \(settingsInk))\n\(summary)")
    }

    /// Share of pixels in `rect` (window coordinates) that differ clearly
    /// from the rect's first pixel (the background).
    static func inkFraction(_ rep: NSBitmapImageRep, rect: NSRect, window: NSWindow) -> Double {
        let scale = CGFloat(rep.pixelsWide) / (window.contentView?.superview?.bounds.width ?? window.frame.width)
        let height = CGFloat(rep.pixelsHigh)
        let x0 = Int(rect.minX * scale), x1 = Int(rect.maxX * scale)
        let y0 = Int(height - rect.maxY * scale), y1 = Int(height - rect.minY * scale)
        guard x1 > x0, y1 > y0, let base = rep.colorAt(x: x0 + 1, y: y0 + 1) else { return 0 }
        var ink = 0, total = 0
        for y in stride(from: y0, to: y1, by: 1) {
            for x in stride(from: x0, to: x1, by: 1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), let b = base.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                if abs(c.redComponent - b.redComponent) + abs(c.greenComponent - b.greenComponent) + abs(c.blueComponent - b.blueComponent) > 0.3 { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }
}
