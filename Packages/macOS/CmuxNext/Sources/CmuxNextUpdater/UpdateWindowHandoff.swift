import AppKit
public import Foundation
public import CmuxNextDesign

/// Restart to Update (cx-ncc.45 S1): what the old windows do when Sparkle
/// commits to a relaunch the person asked for (`updaterWillRelaunchApplication`,
/// right before its installer finishes and quits the app), not at the click.
/// An install nobody clicked leaves the windows as they are. A click
/// whose install never reaches the installer (Sparkle gives up after 7 s:
/// "An error occurred while starting the installer") kept every window
/// transparent for those seconds, and the app looked frozen (slow quit,
/// 2026-10-20).
/// ``mode`` is the one switch (hq-a3 rule 2026-10-10: hide when the click
/// to the relaunched window's first frame takes 300 ms or less, else keep
/// the windows on screen, frozen, with the update card's Installing state
/// as the mark, so the screen never looks like a crash).
///
/// Hidden windows are ordered out, never faded or made transparent (Leo,
/// 2026-11-24: an alpha step read as "the opacity of the window changed"):
/// with the afterimage up over them they leave behind its pictures, so the
/// screen shows no step at all; the old app saves and exits, and the
/// relaunched app opens the same windows from the daemon. Frozen windows stay as they are
/// and take no clicks. Either way the windows stay alive (the quit still
/// saves their launch images and frames), and an install that fails brings
/// them back. With unsaved documents nothing changes: the quit asks about
/// them on screen (decision D2).
@MainActor
public final class UpdateWindowHandoff {
    private struct Hidden {
        weak var window: NSWindow?
        var ignoresMouse: Bool
        var animation: NSWindow.AnimationBehavior
    }

    enum Mode {
        case hide, freeze
    }

    /// The one switch between the two forms.
    static let mode: Mode = .hide

    /// Front first (`NSApp.orderedWindows`), so ``restore()`` brings them back in the same order.
    private var hidden: [Hidden] = []
    /// The windows were ordered out (``leaveScreen()``); a frozen handoff never orders them out.
    private var orderedOut = false
    private let unsaved: QuitUnsavedRegistry
    /// The windows' pictures, when they stay on screen across the relaunch: the windows leave only once the
    /// pictures are up over them, so no frame shows neither.
    private let afterimage: RelaunchAfterimage?

    public init(unsaved: QuitUnsavedRegistry, stateDirectory: URL? = nil) {
        self.unsaved = unsaved
        afterimage = stateDirectory.map { RelaunchAfterimage(stateDirectory: $0) }
    }

    /// Installs the updater's hooks: the windows leave as Sparkle commits to the relaunch, not at the click; a failed
    /// install brings them back. The quit waits for the pictures (``UpdaterService/afterimage``).
    public func attach(to updater: UpdaterService) {
        // The updater keeps this handoff (it holds nothing of the updater's).
        updater.hidesForRelaunch = { _ = self.hide() }
        updater.installAbandoned = { self.restore() }
        updater.afterimage = afterimage
    }

    /// A relaunch is decided (every path: ``UpdaterService/willRelaunch``): the windows are pictured for the afterimage,
    /// unless the quit will ask about unsaved documents (that sheet stays in view).
    public func relaunchDecided() {
        guard unsaved.unsaved().isEmpty else { return }
        afterimage?.begin(activates: NSApp.isActive)
    }

    /// Hides every visible window; false when it did not (unsaved documents).
    @discardableResult
    public func hide() -> Bool {
        guard hidden.isEmpty, unsaved.unsaved().isEmpty else { return false }
        hidden = NSApp.orderedWindows.filter(\.isVisible).map {
            Hidden(window: $0, ignoresMouse: $0.ignoresMouseEvents, animation: $0.animationBehavior)
        }
        for entry in hidden { entry.window?.ignoresMouseEvents = true }
        if Self.mode == .hide {
            // With pictures coming, the windows wait for them (about 100 to 250 ms, the quit's saves run meanwhile).
            if let afterimage, afterimage.isActive { afterimage.whenShown { [weak self] in self?.leaveScreen() } } else { leaveScreen() }
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("windows_\(Self.mode == .hide ? "hidden" : "frozen").\(hidden.count)")
        #endif
        return true
    }

    /// Orders every hidden window out in one transaction, with no close animation: the windows leave
    /// whole in one frame (behind the afterimage when it is up), their alpha never changes. They stay
    /// alive, so the quit still saves their frames and layout.
    private func leaveScreen() {
        guard !hidden.isEmpty else { return }
        orderedOut = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in hidden {
            guard let window = entry.window else { continue }
            window.animationBehavior = .none
            window.orderOut(nil)
        }
        CATransaction.commit()
    }

    /// Brings the hidden windows back as they were, in their old order (the front one last, so it is front).
    public func restore() {
        afterimage?.cancel()
        for entry in hidden.reversed() {
            guard let window = entry.window else { continue }
            window.ignoresMouseEvents = entry.ignoresMouse
            if orderedOut { window.orderFront(nil) }
            window.animationBehavior = entry.animation
        }
        hidden = []
        orderedOut = false
    }
}
