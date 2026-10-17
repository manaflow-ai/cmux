import AppKit
import CmuxBrowser
import CmuxCEF
import Foundation
import Testing
@testable import CmuxCEFBrowser

/// cmux's side panel header over a Chromium page: a subview of the page's
/// host view with a matching hole in the page window.
@MainActor
@Suite
struct CEFSidePanelControllerTests {
    @Test
    func openPanelShowsAHeaderWithAHoleAndClosingRemovesBoth() throws {
        let browser = CEFBrowser(configuration: CEFBrowserConfiguration(profile: UUID()))
        browser.hostView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let controller = CEFSidePanelController(browser: browser, shim: { nil })
        let state = try #require(CEFSidePanelState(json: #"""
        {"open":true,"title":"Notes","pin_visible":true,"pinned":true,"open_in_new_tab":true,"more_info":false,
         "header":{"x":880,"y":0,"width":320,"height":40}}
        """#))

        controller.apply(state, in: browser.hostView)

        let header = try #require(controller.header)
        #expect(header.superview === browser.hostView)
        #expect(header.frame == CGRect(x: 880, y: 760, width: 320, height: 40))
        #expect(browser.hostView.sidePanelHeaderRect == header.frame)
        #expect(header.content == ChromiumSidePanelHeaderContent(
            title: "Notes", icon: nil, isPinned: true, controls: [.pin, .openInNewTab, .close]))

        // No shim (Chromium gone, or the panel closed): the header goes.
        controller.refresh()
        #expect(controller.header == nil)
        #expect(header.superview == nil)
        #expect(browser.hostView.sidePanelHeaderRect == nil)
    }

    @Test
    func controlLabelsFollowThePinState() {
        #expect(ChromiumSidePanelHeaderView.label(for: .pin, pinned: false)
            != ChromiumSidePanelHeaderView.label(for: .pin, pinned: true))
    }
}
