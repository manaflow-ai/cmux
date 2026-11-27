import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// A window resize re-checks the views that keep clear of the traffic lights once, after the layout it causes.
/// Each step of a window corner drag moved the main pane card before the panes in it: the card's move re-checked every
/// avoider (`WindowRootView.onMainPaneMove`, as `WindowController.observeSidebarHidden` wires it) while the views in the
/// card still had their old frames. Home's chat column read the lights as moved on every height change and laid out
/// itself and its glass Chats and compose buttons (a SwiftUI render) at its old frame, then again at its new one: about
/// 2 ms of each corner drag step in NIGHTLY's build and in tree (2026-11-27 `sample` of the main thread: 9% of the
/// window's setFrame, 80 samples under `WindowControlsAvoiders.refresh` in `WindowRootView.layout`).
@MainActor @Suite(.serialized, .closesItsWindows)
struct WindowResizeAvoidersOnceTests {
    /// A workspace that lays out its page in its own layout pass, as the layout root lays out its panes: until then the
    /// page keeps the frame it had.
    final class Workspace: NSView {
        let page: NSView
        init(page: NSView) {
            self.page = page
            super.init(frame: .zero)
            page.autoresizingMask = []
            addSubview(page)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            page.frame = bounds
        }
    }

    final class Moves {
        var count = 0
    }

    /// The window's bottom edge goes down 20 pt a step and its top stays, as in a corner drag: the traffic lights do
    /// not move on screen, so Home's Chats button moves once a step (the column is taller, its buttons stay on the
    /// lights' line), never to a place of the old frame first.
    @Test func aHeightResizeMovesTheChatButtonsOnceAStep() throws {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let saved = design.titlebar
        defer { design.titlebar = saved }
        design.titlebar = .minimal // the main pane card starts at the window's top: the lights lie over Home's top row
        let model = SidebarModel()
        model.presentation = .hidden
        let root = WindowRootView(sidebar: SidebarContainerView(model: model))
        let window = ShellWindow(contentRect: NSRect(x: 200, y: 200, width: 1000, height: 640),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        defer { window.close() }
        window.contentView = root
        root.sidebar.isHidden = true
        root.sidebarHidden = true
        // WindowController.observeSidebarHidden: each move of the main pane card re-checks the window's avoiders.
        root.onMainPaneMove = { [weak window] in WindowControlsAvoiders.refresh(in: window) }
        let column = HomeChatColumnView(content: NSView(), compose: HomeChatComposeButton(label: "New Message"))
        column.showsCompose = true
        root.show(Workspace(page: column))
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        try #require(window.windowControlsAvoiders.count >= 1, "SETUP: the chat column did not join the window's avoiders")
        try #require(column.homeLightsRow(band: HomeSidebarHeaderLayout.band) != nil,
                     "SETUP: the traffic lights do not lie over the chat column's top row")

        let moves = Moves()
        column.chats.postsFrameChangedNotifications = true
        // global-notice-allow: AppKit posts a view's frame notice on the default center only; this observes one button
        let token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: column.chats,
                                                           queue: nil) { _ in
            MainActor.assumeIsolated { moves.count += 1 } // main-proof: AppKit posts a view's frame notice on the main thread
        }
        defer { NotificationCenter.default.removeObserver(token) }

        for step in 1...4 {
            moves.count = 0
            var frame = window.frame
            frame.origin.y -= 20
            frame.size.height += 20
            window.setFrame(frame, display: true)
            window.layoutIfNeeded()
            #expect(moves.count == 1, "step \(step): the Chats button moved \(moves.count) times for one resize")
            let lights = try #require(TrafficLightsLine.restingFrame(in: window), "step \(step): no traffic lights")
            let chats = column.chats.convert(column.chats.bounds, to: nil)
            #expect(abs(chats.midY - lights.midY) <= 1, "step \(step): the Chats button left the lights' line: \(chats) against \(lights)")
        }
    }
}
