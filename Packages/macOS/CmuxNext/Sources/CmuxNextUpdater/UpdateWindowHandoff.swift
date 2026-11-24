import AppKit
import Foundation
public import CmuxNextDesign

/// Restart to Update is a plain quit and relaunch (Leo, 2026-11-24: "we want to have the restrat to update
/// working as people expect (not the wannabe smooth transition thing) and have it be fast and good"):
/// Sparkle installs, the app quits, the relaunched app restores its windows, workspaces and sessions from
/// the daemon the normal way. Nothing pictures the old windows or holds them on screen across the relaunch.
///
/// What this does is the quit's own look: when Sparkle commits to a relaunch the person asked for
/// (`updaterWillRelaunchApplication`, right before its installer finishes and quits the app), not at the
/// click, every visible window leaves the screen at once, as a quit's windows do, while the quit saves.
/// An install nobody clicked leaves the windows as they are. A click whose install never reaches the
/// installer (Sparkle gives up after 7 s: "An error occurred while starting the installer") brings them
/// back (``restore()``).
///
/// Windows are ordered out, never faded or made transparent (Leo, 2026-11-24: an alpha step read as "the
/// opacity of the window changed"). They stay alive, so the quit still saves their launch images, frames
/// and layout. With unsaved documents nothing changes: the quit asks about them on screen (decision D2).
@MainActor
public final class UpdateWindowHandoff {
    private struct Hidden {
        weak var window: NSWindow?
        var ignoresMouse: Bool
        var animation: NSWindow.AnimationBehavior
    }

    /// Front first (`NSApp.orderedWindows`), so ``restore()`` brings them back in the same order.
    private var hidden: [Hidden] = []
    private let unsaved: QuitUnsavedRegistry

    public init(unsaved: QuitUnsavedRegistry) {
        self.unsaved = unsaved
    }

    /// Installs the updater's hooks: the windows leave as Sparkle commits to the relaunch, not at the click; a failed
    /// install brings them back.
    public func attach(to updater: UpdaterService) {
        // The updater keeps this handoff (it holds nothing of the updater's).
        updater.hidesForRelaunch = { _ = self.hide() }
        updater.installAbandoned = { self.restore() }
    }

    /// Orders every visible window out in one transaction, with no close animation; false when it did not
    /// (unsaved documents).
    @discardableResult
    public func hide() -> Bool {
        guard hidden.isEmpty, unsaved.unsaved().isEmpty else { return false }
        hidden = NSApp.orderedWindows.filter(\.isVisible).map {
            Hidden(window: $0, ignoresMouse: $0.ignoresMouseEvents, animation: $0.animationBehavior)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in hidden {
            guard let window = entry.window else { continue }
            window.ignoresMouseEvents = true
            window.animationBehavior = .none
            window.orderOut(nil)
        }
        CATransaction.commit()
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("windows_hidden.\(hidden.count)")
        #endif
        return true
    }

    /// Brings the hidden windows back as they were, in their old order (the front one last, so it is front).
    public func restore() {
        for entry in hidden.reversed() {
            guard let window = entry.window else { continue }
            window.ignoresMouseEvents = entry.ignoresMouse
            window.orderFront(nil)
            window.animationBehavior = entry.animation
        }
        hidden = []
    }
}
