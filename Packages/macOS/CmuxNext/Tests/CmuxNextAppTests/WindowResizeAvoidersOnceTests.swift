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

    /// `-[NSView layout]` calls of Home's chat column since launch (`LayoutPassGuard`, by class).
    static func columnLayouts() -> Int {
        let name = String(describing: HomeChatColumnView.self)
        return LayoutPassGuard.shared.passesByClass.reduce(0) { $0 + ($1.viewClass == name ? $1.passes : 0) }
    }

    /// The window's bottom edge goes down 20 pt a step and its top stays, as in a corner drag: the traffic lights do
    /// not move on screen, so Home's chat column lays out once a step and its Chats button moves once (the column is
    /// taller, its buttons stay on the lights' line), never at the old frame first. Both are counted: the column's
    /// layouts are the cost (its glass buttons render at each), and a stale layout that put the button where the final
    /// one puts it again would move it no more than once.
    @Test func aHeightResizeLaysOutTheChatColumnOnceAStep() throws {
        _ = NSApplication.shared
        LayoutPassGuard.shared.install()
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
        root.refreshesAvoidersOnMainPaneMove() // as WindowController.observeSidebarHidden wires it
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
            let layoutsBefore = Self.columnLayouts()
            var frame = window.frame
            frame.origin.y -= 20
            frame.size.height += 20
            window.setFrame(frame, display: true)
            window.layoutIfNeeded()
            let layouts = Self.columnLayouts() - layoutsBefore
            #expect(layouts == 1, "step \(step): the chat column laid out \(layouts) times for one resize")
            #expect(moves.count == 1, "step \(step): the Chats button moved \(moves.count) times for one resize")
            let lights = try #require(TrafficLightsLine.restingFrame(in: window), "step \(step): no traffic lights")
            let chats = column.chats.convert(column.chats.bounds, to: nil)
            #expect(abs(chats.midY - lights.midY) <= 1, "step \(step): the Chats button left the lights' line: \(chats) against \(lights)")
        }
    }

    /// A view that counts its re-checks.
    final class CheckCounter: NSView, WindowControlsAvoiding {
        var checks = 0
        func updateWindowControlsAvoidance() { checks += 1 }
    }

    /// A content view that asks its window's avoiders to re-check in each of its frame changes and layouts, as the main
    /// pane card's move does (`WindowRootView.onMainPaneMove`), and notes how many re-checks had run when it asked.
    final class AskingContent: NSView {
        let probe: CheckCounter
        var seenInFrameChange: [Int] = []
        var seenInLayout: [Int] = []
        init(probe: CheckCounter) {
            self.probe = probe
            super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            guard let window else { return }
            WindowControlsAvoiders.refresh(in: window)
            seenInFrameChange.append(probe.checks)
        }

        override func layout() {
            super.layout()
            WindowControlsAvoiders.refresh(in: window)
            seenInLayout.append(probe.checks)
        }
    }

    /// The window's two wrappers, each on its own: a re-check asked inside the window's frame change (`setFrame`, where a
    /// live resize's step lays out) runs once at its end, and so does one asked inside the window's layout pass
    /// (`layoutIfNeeded`), never inside either. Whichever of the two lays the window out in the test above, the other is
    /// pinned here.
    @Test func aReCheckAskedInAFrameChangeOrALayoutPassRunsAtItsEnd() {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let probe = CheckCounter(frame: NSRect(x: 0, y: 360, width: 100, height: 40))
        let content = AskingContent(probe: probe)
        window.contentView = content
        content.addSubview(probe)
        WindowControlsAvoiders.join(probe)
        window.layoutIfNeeded()

        probe.checks = 0
        content.seenInFrameChange = []
        content.seenInLayout = []
        var frame = window.frame
        frame.size.height += 20
        window.setFrame(frame, display: false)
        #expect(!content.seenInFrameChange.isEmpty, "SETUP: the content view's frame did not change in the window's")
        #expect(content.seenInFrameChange.allSatisfy { $0 == 0 },
                "a re-check asked in the window's frame change ran inside it: \(content.seenInFrameChange)")
        #expect(content.seenInLayout.allSatisfy { $0 == 0 },
                "a re-check asked in a layout inside the window's frame change ran inside it: \(content.seenInLayout)")
        #expect(probe.checks == 1, "the re-checks asked in the window's frame change ran \(probe.checks) times at its end")

        content.seenInLayout = []
        content.needsLayout = true
        window.layoutIfNeeded()
        #expect(!content.seenInLayout.isEmpty, "SETUP: the window's layout pass did not lay out its content view")
        #expect(content.seenInLayout.allSatisfy { $0 == 1 },
                "a re-check asked in the window's layout pass ran inside it: \(content.seenInLayout)")
        #expect(probe.checks == 2, "the re-checks asked in the window's layout pass ran \(probe.checks - 1) times at its end")
    }

    /// Runs the main run loop in `mode` until it has slept once (a timer in that mode wakes it), as the app's event loop
    /// and a live resize's or a menu's tracking loop do between events. In the app AppKit makes the event-tracking mode
    /// one of the main run loop's common modes; this makes sure the test process has it too.
    static func sleepOnce(in mode: RunLoop.Mode) {
        let cfMode = CFRunLoopMode(rawValue: mode.rawValue as CFString)
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), cfMode)
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: mode)
        _ = CFRunLoopRunInMode(cfMode, 0.05, false)
        timer.invalidate()
    }

    /// A batch an exception left open ends when the main run loop next goes to sleep, in each of its common modes. AppKit
    /// catches an Objective-C exception thrown in a layout pass (a layout loop it stops), which skips the Swift `defer`
    /// that ends the batch: every later re-check of the window then waited for an end that never came. A Swift test
    /// cannot raise and catch one, so the batch's body runs the main run loop in the event-tracking mode (a live resize's
    /// tracking loop, where the app's event loop does not run) until it sleeps, while the batch is open: the re-check
    /// asked before runs there, one asked after runs at once, and once the body ends the next re-check runs at once too
    /// (the batch's own end does not count it twice).
    @Test func theRunLoopsSleepEndsABatchLeftOpen() {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let probe = CheckCounter(frame: NSRect(x: 0, y: 360, width: 100, height: 40))
        content.addSubview(probe)
        WindowControlsAvoiders.join(probe)
        window.windowControlsAvoiders.batching(in: window) {
            WindowControlsAvoiders.refresh(in: window)
            #expect(probe.checks == 0, "a re-check inside a batch ran before its end")
            Self.sleepOnce(in: .eventTracking)
            #expect(probe.checks == 1, "the run loop's sleep did not run the re-check an open batch held")
            WindowControlsAvoiders.refresh(in: window)
            #expect(probe.checks == 2, "after the run loop's sleep a re-check still waited for the batch's end")
        }
        WindowControlsAvoiders.refresh(in: window)
        #expect(probe.checks == 3, "after the batch a re-check waited: the batch's end left it open")
    }
}
