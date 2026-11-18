public import AppKit
public import CmuxNextWakeups
import Foundation
import os

/// When a Home view that was just made starts the Chief's brain host (`HomeService.homeDidOpen`).
///
/// `CMUX_NEXT_CHIEF_START=visible` (a prototype for the idle-memory goal; the default is unchanged): a Home
/// view made off screen (a docked Home tab never shown, a workspace not in front) does not start it; it
/// starts once that view is on screen, in a visible window that is not out of sight
/// (``FrameScheduler/windowIsOutOfSight(_:)``) and with no hidden ancestor. The first Chief use (a
/// person's message to the Chief, a Chief chat, the engine panel) asks ``ChiefBrainKeeper`` directly, so it
/// starts the host either way. Unset or any other value: every Home view made starts it at once, as before.
///
/// The watch rides along as a zero-size subview of that view, so it hears the view move into a window
/// (`viewDidMoveToWindow`), an ancestor unhide (`viewDidUnhide`) and its window's occlusion reports (the
/// app's one occlusion observer, ``FrameScheduler/followSight(of:owner:_:)``), with no polling; it goes once
/// it has run. Each ask logs `chief start asked from <caller> on_screen <bool>`, so a
/// launch says which Home view asked.
@MainActor
public final class HomeShownWatch: NSView {
    /// `CMUX_NEXT_CHIEF_START=visible`.
    public static let waitsForScreen = (ProcessInfo.processInfo.environment["CMUX_NEXT_CHIEF_START"] ?? "visible") == "visible"
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
    private var start: (@MainActor () -> Void)?
    private weak var followed: NSWindow?

    /// Runs `start` (the brain host's start for Home view `view`, made by `caller`) now, or with
    /// ``waitsForScreen`` once `view` is on screen; a later ask on the same view takes the earlier one's place.
    public static func startChief(for view: NSView, from caller: String, _ start: @escaping @MainActor () -> Void) {
        let onScreen = isOnScreen(view)
        logger.notice("chief start asked from \(caller, privacy: .public) on_screen \(onScreen, privacy: .public) waits_for_screen \(waitsForScreen, privacy: .public)")
        guard waitsForScreen, !onScreen else { return start() }
        let watch = view.subviews.lazy.compactMap { $0 as? HomeShownWatch }.first ?? {
            let made = HomeShownWatch(frame: .zero)
            view.addSubview(made)
            return made
        }()
        watch.start = start
        watch.follow(watch.window)
    }

    /// Whether `view` is on screen now.
    static func isOnScreen(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible, !FrameScheduler.windowIsOutOfSight(window) else { return false }
        return !view.isHiddenOrHasHiddenAncestor
    }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        follow(window)
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        check()
    }

    /// Hears `window`'s occlusion reports (ordered in, uncovered), then checks now.
    private func follow(_ window: NSWindow?) {
        if let followed, followed !== window { FrameScheduler.unfollowSight(of: followed, owner: self) }
        followed = window
        if let window { FrameScheduler.followSight(of: window, owner: self) { [weak self] in self?.check() } }
        check()
    }

    private func check() {
        guard let start, let host = superview, Self.isOnScreen(host) else { return }
        self.start = nil
        if let followed { FrameScheduler.unfollowSight(of: followed, owner: self) }
        followed = nil
        removeFromSuperview()
        start()
    }
}
