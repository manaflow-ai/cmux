import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing
import AppKit

/// The footer's Live button (RFD 0141 phase 1): right after the profile avatar, never over Search or the Spaces dots'
/// start, hidden by `sidebar.showLiveToggle` (off by default: Leo 2026-11-25 didn't want it on by default), a click runs
/// `onLiveToggle`, and the right-click menu lists people.
@MainActor @Suite(.serialized) struct SidebarLiveToggleTests {
    private static func make(spaces: SpacesPosition, showToggle: Bool = true) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        design.sidebarSections.showLiveToggle = showToggle
        design.sidebarSections.showSearchButton = true
        design.sidebarSections.noFade = false
        let sidebar = SidebarView(model: SidebarModel(), design: design)
        sidebar.spacesPosition = spaces
        sidebar.frame = NSRect(x: 0, y: 0, width: Metrics.sidebarWidth, height: 600)
        let window = NSWindow(contentRect: sidebar.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    @Test(arguments: [SpacesPosition.bottom, .top])
    func liveButtonSitsLeftOfSearchWithoutOverlap(_ spaces: SpacesPosition) {
        let saved = (DesignSettings.shared.sidebarSections.showLiveToggle, DesignSettings.shared.sidebarSections.showSearchButton,
                     DesignSettings.shared.sidebarSections.noFade)
        defer { (DesignSettings.shared.sidebarSections.showLiveToggle, DesignSettings.shared.sidebarSections.showSearchButton,
                 DesignSettings.shared.sidebarSections.noFade) = saved }
        let (sidebar, window) = Self.make(spaces: spaces)
        defer { window.close() }
        let live = sidebar.liveButton.frame
        #expect(!sidebar.liveButton.isHidden)
        #expect(live.width > 0)
        #expect(live.maxX <= sidebar.searchButton.frame.minX, "Live \(live) overlaps Search \(sidebar.searchButton.frame)")
        if let badge = sidebar.liveModeBadge, !badge.isHidden, badge.frame.width > 0 {
            #expect(badge.frame.minX >= live.maxX, "badge \(badge.frame) overlaps Live \(live)")
        }
    }

    /// Out of the box the footer has no Live button: a fresh sidebar's design hides it, and nothing else on the
    /// footer line moves for it.
    @Test func hiddenByDefault() {
        #expect(SidebarSectionsPreferences.defaults.showLiveToggle == false)
        let saved = DesignSettings.shared.sidebarSections
        defer { DesignSettings.shared.sidebarSections = saved }
        DesignSettings.shared.sidebarSections = .defaults
        _ = NSApplication.shared
        let sidebar = SidebarView(model: SidebarModel(), design: DesignSettings.shared)
        sidebar.frame = NSRect(x: 0, y: 0, width: Metrics.sidebarWidth, height: 600)
        let window = NSWindow(contentRect: sidebar.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { window.close() }
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.liveButton.isHidden)
    }

    @Test func hiddenWhenTheSettingIsOff() {
        let saved = DesignSettings.shared.sidebarSections.showLiveToggle
        defer { DesignSettings.shared.sidebarSections.showLiveToggle = saved }
        let (sidebar, window) = Self.make(spaces: .bottom, showToggle: false)
        defer { window.close() }
        #expect(sidebar.liveButton.isHidden)
    }

    @Test func clickAndMenu() {
        let saved = DesignSettings.shared.sidebarSections.showLiveToggle
        defer { DesignSettings.shared.sidebarSections.showLiveToggle = saved }
        let (sidebar, window) = Self.make(spaces: .bottom)
        defer { window.close() }
        var toggles = 0
        sidebar.onLiveToggle = { toggles += 1 }
        sidebar.live = SidebarLiveState(isLive: true, people: [.init(id: "p1", name: "Ada", isLive: true), .init(id: "p2", name: "Bo", isLive: false)])
        sidebar.liveButton.onPress?()
        #expect(toggles == 1)
        let titles = sidebar.liveMenu().items.map(\.title)
        #expect(titles.contains { $0.hasSuffix("Ada") })
        #expect(titles.contains(Strings.liveTurnOff))
    }
}
