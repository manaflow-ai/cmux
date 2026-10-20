import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar's Search button (plans/cmux-next/sidebar-search.md; Lawrence 2026-10-20: "in sidebar
/// bottom left we should add a search icon button for search"): a magnifying glass in the footer row
/// right after the profile avatar, a full hit target, labeled for VoiceOver, that hands its own view
/// to the App as the palette's anchor. `sidebar.showSearchButton` off hides it.
@MainActor @Suite(.serialized) struct SidebarSearchButtonTests {
    struct Harness {
        let model: SidebarModel
        let design: DesignSettings
        let sidebar: SidebarView
        let window: NSWindow

        func settle() {
            sidebar.renderNow()
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }

        func frame(of view: NSView) -> NSRect { sidebar.convert(view.bounds, from: view) }
    }

    private func make() async -> Harness {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.profileAvatar = SidebarAvatar(name: "Default", color: .blue)
        let design = DesignSettings()
        let sidebar = SidebarView(model: model, design: design)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let harness = Harness(model: model, design: design, sidebar: sidebar, window: window)
        for _ in 0..<20 {
            harness.settle()
            if sidebar.footerBand.profileControl != nil { break }
            await Task.yield()
        }
        harness.settle()
        return harness
    }

    @Test func theFooterShowsASearchButtonAfterTheAvatar() async throws {
        let h = await make()
        defer { h.window.close() }
        let button = h.sidebar.searchButton
        #expect(button.superview != nil && !button.isHidden && button.alphaValue > 0.5, "the search button shows")
        #expect(button.accessibilityIdentifier() == "cmux.sidebar.search")
        #expect(button.accessibilityLabel() == Strings.searchButton)

        let frame = h.frame(of: button)
        // A full hit target (the avatar's 28 pt square), not a glyph-sized one.
        #expect(frame.width >= 28 && frame.height >= 28, "hit target \(frame.size)")
        // In the footer row, at the sidebar's bottom.
        #expect(frame.maxY <= h.sidebar.bounds.maxY && frame.minY >= h.sidebar.bounds.maxY - 3 * frame.height, "frame \(frame)")
        // Right after the avatar, on its line.
        let avatar = try #require(h.sidebar.footerBand.profileControl?.view)
        let avatarFrame = h.frame(of: avatar)
        #expect(frame.minX >= avatarFrame.maxX, "search \(frame) after avatar \(avatarFrame)")
        #expect(frame.minX - avatarFrame.maxX <= 12, "search \(frame) beside avatar \(avatarFrame)")
        #expect(abs(frame.midY - avatarFrame.midY) <= 1, "search \(frame) on the avatar's line \(avatarFrame)")
        // The spaces dots never cover it.
        if !h.sidebar.profileBar.isHidden {
            #expect(!h.frame(of: h.sidebar.profileBar).intersects(frame) || h.sidebar.profileBar.leadingInset != nil,
                    "dots \(h.frame(of: h.sidebar.profileBar)) over search \(frame)")
        }
    }

    @Test func pressingTheButtonOpensSearchAnchoredToIt() async {
        let h = await make()
        defer { h.window.close() }
        var anchors: [NSView] = []
        h.sidebar.onSearch = { anchors.append($0) }
        h.sidebar.searchButton.performClick(nil)
        #expect(anchors.count == 1)
        #expect(anchors.first === h.sidebar.searchButton)
    }

    @Test func theSettingHidesTheButton() async {
        let h = await make()
        defer { h.window.close() }
        var preferences = h.design.sidebarSections
        preferences.showSearchButton = false
        h.design.sidebarSections = preferences
        for _ in 0..<20 {
            h.settle()
            if h.sidebar.searchButton.isHidden { break }
            await Task.yield()
        }
        #expect(h.sidebar.searchButton.isHidden)
    }
}
