import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar's bottom-left profile control: the avatar and a menu chevron on
/// one chip where the footer has room (the name only in its tooltip and menu,
/// Lawrence 2026-10-20), the Search button and the spaces dots after it; the
/// avatar alone in a narrow sidebar.
@MainActor @Suite(.serialized) struct SidebarProfileChipTests {
    struct Harness {
        let sidebar: SidebarView
        let window: NSWindow

        func settle() {
            sidebar.renderNow()
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }

        func frame(of view: NSView) -> NSRect { sidebar.convert(view.bounds, from: view) }
    }

    private func make(width: CGFloat) async -> Harness {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.profileAvatar = SidebarAvatar(name: "Default", color: .blue)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let harness = Harness(sidebar: sidebar, window: window)
        for _ in 0..<20 {
            harness.settle()
            if sidebar.footerBand.profileControl != nil { break }
            await Task.yield()
        }
        harness.settle()
        return harness
    }

    // Lawrence (owner, 2026-10-20): "should not show name down here, only icon". The name
    // moves to the tooltip and the menu; the chevron still marks the menu.
    @Test func aRoomyFooterShowsTheAvatarAndChevronButNotTheName() async throws {
        let h = await make(width: 240)
        defer { h.window.close() }
        let control = try #require(h.sidebar.footerBand.profileControl?.view)
        control.layoutSubtreeIfNeeded()
        #expect(control.showsAvatar)
        #expect(control.titleFrame == .zero, "no name in the footer")
        #expect(control.themedToolTip?.hasPrefix("Default") == true, "the name is the tooltip")
        let frame = h.frame(of: control)
        #expect(frame.width > frame.height && frame.width < frame.height * 2.5, "avatar and chevron only: \(frame)")
        // The avatar leads, then the chevron.
        let circle = control.convert(control.avatarView.circleFrame, from: control.avatarView)
        #expect(!control.icon.isHidden && control.icon.image != nil, "the chevron draws")
        #expect(circle.minX >= 0 && control.icon.frame.minX >= circle.maxX && control.icon.frame.maxX <= control.bounds.width,
                "chevron \(control.icon.frame) after avatar \(circle)")

        // The band's items end after the chip; Search and the dots sit after it.
        let row = try #require(h.sidebar.footerBand.bandFirstRow)
        #expect(row.itemsMaxX >= frame.maxX - 0.5, "itemsMaxX \(row.itemsMaxX) past the chip \(frame)")
        let search = h.frame(of: h.sidebar.searchButton)
        #expect(!h.sidebar.searchButton.isHidden && search.minX >= frame.maxX, "search \(search) after chip \(frame)")
        #expect(search.maxX <= h.sidebar.bounds.maxX, "search \(search) inside the sidebar")
        if !h.sidebar.profileBar.isHidden, h.sidebar.profileBar.superview === h.sidebar {
            #expect(h.frame(of: h.sidebar.profileBar).minX >= search.maxX - 0.5, "dots after search")
        }
    }

    @Test func aNarrowFooterKeepsTheAvatarAlone() async throws {
        let h = await make(width: 120)
        defer { h.window.close() }
        let control = try #require(h.sidebar.footerBand.profileControl?.view)
        control.layoutSubtreeIfNeeded()
        #expect(control.showsAvatar)
        #expect(control.titleFrame == .zero, "no name where it does not fit")
        let frame = h.frame(of: control)
        #expect(abs(frame.width - frame.height) < 0.5, "the avatar's square: \(frame)")
    }

    @Test func theChipHoldsAFillWhileItsMenuIsOpen() async throws {
        let h = await make(width: 240)
        defer { h.window.close() }
        let control = try #require(h.sidebar.footerBand.profileControl?.view)
        #expect(control.isProfileChip)
        #expect(control.fill == nil, "no fill at rest")
        control.showsMenu = true
        #expect(control.fill != nil, "the open menu's control shows a fill")
        control.showsMenu = false
        #expect(control.fill == nil, "the fill clears when the menu closes")
    }
}
