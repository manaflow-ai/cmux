import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Chrome-parity p14-energy-055a (Q5 tracking areas): the sidebar's hover tracking runs only while
/// cmux is the active app. An `.activeAlways` area made AppKit wake cmux for every mouse move over
/// its window while another app was in front, for a hover tint nobody acts on there. The sidebar's
/// hover is chrome, not page content, so none of it needs an inactive app's hover (the list also
/// clears its hover when the app resigns active, `SidebarListView.observeFocusLoss`).
@MainActor @Suite(.serialized)
struct SidebarTrackingAreaActivationTests {
    /// Every sidebar view that owns a tracking area, one per `.activeAlways` site this task changed.
    private static func trackingViews() -> [NSView] {
        [
            SidebarCardTextButton(frame: .zero),
            SidebarUpdateCardView(frame: .zero),
            SidebarUpdateButton(frame: .zero),
            SidebarEnergyCardView(frame: .zero),
            SidebarListView(model: SidebarModel(sections: [])),
            ProfileBarView(model: SidebarModel()),
            SidebarPopoverIslandHost(width: 240),
            SidebarRailView(),
            SidebarGroupSwatchView(color: .blue),
            SidebarGroupEditorRow(SidebarGroupEditorItem(id: "ungroup", title: "Ungroup")),
            SidebarPullRequestCardRow(frame: .zero),
        ]
    }

    @Test func everySidebarHoverTracksOnlyWhileCmuxIsActive() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: .borderless,
                              backing: .buffered, defer: true)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        for view in Self.trackingViews() {
            window.contentView?.addSubview(view)
            view.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
            view.updateTrackingAreas()
            let name = String(describing: type(of: view))
            let own = view.trackingAreas.filter { $0.owner === view }
            #expect(!own.isEmpty, "\(name) tracks no hover; the test no longer covers its area")
            for area in own {
                #expect(!area.options.contains(.activeAlways), "\(name) wakes cmux for mouse moves while another app is in front")
                #expect(area.options.contains(.activeInActiveApp), "\(name) tracks hover in neither the active app nor always")
            }
            view.removeFromSuperview()
        }
    }
}
