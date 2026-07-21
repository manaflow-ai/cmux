import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@MainActor
@Suite struct SidebarContentLayoutViewTests {
    private func makeLayout(
        mode: SidebarContentLayoutMode = .sideBySide,
        isSidebarVisible: Bool = true,
        width: CGFloat = 240
    ) -> SidebarContentLayoutView {
        SidebarContentLayoutView(
            sidebarView: NSView(),
            mainContentView: NSView(),
            dividerView: NSView(),
            configuration: SidebarContentLayoutConfiguration(
                sidebarWidth: width,
                isSidebarVisible: isSidebarVisible,
                mode: mode,
                dividerLeadingHitWidth: 6,
                dividerTrailingHitWidth: 4
            )
        )
    }

    @Test func sideBySideModePlacesContentAfterSidebar() {
        let layout = makeLayout()
        layout.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        layout.layoutSubtreeIfNeeded()

        #expect(layout.sidebarView.frame == NSRect(x: 0, y: 0, width: 240, height: 600))
        #expect(layout.mainContentView.frame == NSRect(x: 240, y: 0, width: 660, height: 600))
        #expect(layout.dividerView.frame == NSRect(x: 234, y: 0, width: 10, height: 600))
    }

    @Test func overlayModeKeepsContentFullWidthUnderSidebar() {
        let layout = makeLayout(mode: .overlay)
        layout.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        layout.layoutSubtreeIfNeeded()

        #expect(layout.sidebarView.frame == NSRect(x: 0, y: 0, width: 240, height: 600))
        #expect(layout.mainContentView.frame == NSRect(x: 0, y: 0, width: 900, height: 600))
        #expect(layout.dividerView.frame == NSRect(x: 234, y: 0, width: 10, height: 600))
    }

    @Test func hiddenSidebarGivesContentTheEntireBounds() {
        let layout = makeLayout(isSidebarVisible: false)
        layout.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        layout.layoutSubtreeIfNeeded()

        #expect(layout.sidebarView.isHidden)
        #expect(layout.dividerView.isHidden)
        #expect(layout.sidebarView.frame == .zero)
        #expect(layout.mainContentView.frame == NSRect(x: 0, y: 0, width: 900, height: 600))
    }

    @Test func applyingWidthSynchronouslyUpdatesAllFrames() {
        let layout = makeLayout()
        layout.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        layout.layoutSubtreeIfNeeded()

        layout.apply(
            configuration: SidebarContentLayoutConfiguration(
                sidebarWidth: 320,
                isSidebarVisible: true,
                mode: .sideBySide,
                dividerLeadingHitWidth: 6,
                dividerTrailingHitWidth: 4
            )
        )

        #expect(layout.sidebarView.frame.width == 320)
        #expect(layout.mainContentView.frame == NSRect(x: 320, y: 0, width: 580, height: 600))
        #expect(layout.dividerView.frame.minX == 314)
    }

    @Test func sidebarWidthIsClampedToContainerBounds() {
        let layout = makeLayout(width: 1_200)
        layout.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        layout.layoutSubtreeIfNeeded()

        #expect(layout.sidebarView.frame.width == 900)
        #expect(layout.mainContentView.frame.width == 0)
        #expect(layout.dividerView.frame.minX == 894)
    }
}
