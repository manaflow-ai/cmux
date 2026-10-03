import AppKit
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
    }
}
