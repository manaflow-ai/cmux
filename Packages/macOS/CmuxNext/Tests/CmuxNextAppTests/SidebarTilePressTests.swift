import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Review of #22659: a press on a tile while an earlier tile drag is still alive (its release went to
/// another window, never here) left that drag held, its card lifted and its tile hidden. A new press
/// means the old one ended: the stale drag is cancelled, as a press on the list's rows already does.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarTilePressTests {
    static let link = LayoutItemID("itm_link"), app = LayoutItemID("itm_app")

    final class Band {
        let region = SidebarRegionView(region: .top)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init() {
            let items = [LayoutItem(id: SidebarTilePressTests.link, ref: .url("https://example.com")),
                         LayoutItem(id: SidebarTilePressTests.app, ref: .app("acme/notes"))]
            let section = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: items)
            let content = SidebarRegionView.Content(sections: [section], infos: [:], collapsed: [], look: SidebarSectionTunables.currentLook,
                                                    metrics: .standard, drawsLines: false)
            region.frame = NSRect(x: 0, y: 0, width: 240, height: 360)
            region.update(content, width: 240)
            window.contentView = region
            window.orderFrontRegardless()
            region.layoutSubtreeIfNeeded()
        }

        func view(_ id: LayoutItemID) throws -> SidebarItemRowView {
            let view = try #require(region.itemView(id), "the band draws no \(id.rawValue) item")
            view.layoutSubtreeIfNeeded()
            return view
        }

        func event(_ type: NSEvent.EventType, on view: NSView, dy: CGFloat = 0) throws -> NSEvent {
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY + dy), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                   pressure: type == .leftMouseUp ? 0 : 1))
        }
    }

    @Test func aPressOnATileCancelsAStaleTileDrag() throws {
        let band = Band()
        defer { band.window.closeAfterTest() }
        let link = try band.view(Self.link)
        link.mouseDown(with: try band.event(.leftMouseDown, on: link))
        link.mouseDragged(with: try band.event(.leftMouseDragged, on: link, dy: 40))
        #expect(band.region.reorder != nil, "the fixture's drag did not start")

        // The release never came; the next press lands on another tile.
        let app = try band.view(Self.app)
        app.mouseDown(with: try band.event(.leftMouseDown, on: app))
        #expect(band.region.reorder == nil, "the stale drag is still held under the new press")
        #expect(band.region.reorderSections == nil, "the stale drag's moved order still shows")
        app.mouseUp(with: try band.event(.leftMouseUp, on: app))
    }
}
