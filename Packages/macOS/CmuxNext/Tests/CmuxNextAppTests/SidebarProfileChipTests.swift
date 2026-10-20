import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar's bottom-left profile control (Leo 2026-10-20): the avatar and
/// the profile's name on one chip where the footer has room, the Search button
/// and the spaces dots after it; the avatar alone in a narrow sidebar.
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

    @Test func aRoomyFooterShowsTheAvatarAndTheName() async throws {
        let h = await make(width: 240)
        defer { h.window.close() }
        let control = try #require(h.sidebar.footerBand.profileControl?.view)
        control.layoutSubtreeIfNeeded()
        #expect(control.showsAvatar)
        #expect(control.titleText == "Default")
        #expect(control.titleFrame.width > 0, "the name draws beside the avatar")
        let frame = h.frame(of: control)
        #expect(frame.width > frame.height, "a chip, not the avatar's square: \(frame)")
        // The avatar leads, then the name.
        let circle = control.convert(control.avatarView.circleFrame, from: control.avatarView)
        #expect(circle.minX >= 0 && circle.maxX <= control.titleFrame.minX, "avatar \(circle) before name \(control.titleFrame)")
        #expect(control.titleFrame.maxX <= control.bounds.width)

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
}
