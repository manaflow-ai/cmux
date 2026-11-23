import AppKit
public import Foundation
public import CmuxNextDesign

/// Restart to Update (cx-ncc.45 S1): what the old windows do when Sparkle
/// commits to a relaunch the person asked for (`updaterWillRelaunchApplication`,
/// right before its installer finishes and quits the app), not at the click.
/// An install nobody clicked leaves the windows as they are.
///
/// They stay on screen exactly as they are, frozen: no hide, no fade, no
/// other transition. They take no clicks while the old app saves and exits,
/// and the relaunched app opens the same windows from the daemon and their
/// launch images. Leo, 2026-11-22, overriding the hq-a3 rule (2026-10-10)
/// that hid them (alpha 0) when the click to the relaunched window's first
/// frame took 300 ms or less: "the hide then animation then going to the
/// updated to nightly is just bad."
///
/// When the old process ends, the relaunch's afterimage (``RelaunchAfterimage``,
/// pictures of these same windows) stays up until the new process drew them,
/// so the screen never shows neither.
///
/// The windows stay alive (the quit still saves their launch images and
/// frames), and an install that fails gives them their clicks back
/// (``restore()``); a click whose install never reaches the installer
/// (Sparkle gives up after 7 s) never froze them. With unsaved documents
/// nothing changes: the quit asks about them on screen (decision D2).
@MainActor
public final class UpdateWindowHandoff {
    private struct Frozen {
        weak var window: NSWindow?
        var ignoresMouse: Bool
    }

    private var frozen: [Frozen] = []
    private let unsaved: QuitUnsavedRegistry
    /// The windows' pictures, up over the frozen windows across the relaunch: when the old process ends, they
    /// stay until the new process drew its windows, so no frame shows neither.
    private let afterimage: RelaunchAfterimage?

    public init(unsaved: QuitUnsavedRegistry, stateDirectory: URL? = nil) {
        self.unsaved = unsaved
        afterimage = stateDirectory.map { RelaunchAfterimage(stateDirectory: $0) }
    }

    /// Installs the updater's hooks: the windows freeze as Sparkle commits to the relaunch, not at the click; a failed
    /// install unfreezes them. The quit waits for the pictures (``UpdaterService/afterimage``).
    public func attach(to updater: UpdaterService) {
        // The updater keeps this handoff (it holds nothing of the updater's).
        updater.freezesForRelaunch = { _ = self.freeze() }
        updater.installAbandoned = { self.restore() }
        updater.afterimage = afterimage
    }

    /// A relaunch is decided (every path: ``UpdaterService/willRelaunch``): the windows are pictured for the afterimage,
    /// unless the quit will ask about unsaved documents (that sheet stays in view).
    public func relaunchDecided() {
        guard unsaved.unsaved().isEmpty else { return }
        afterimage?.begin(activates: NSApp.isActive)
    }

    /// Freezes every visible window where it is; false when it did not (unsaved documents).
    @discardableResult
    public func freeze() -> Bool {
        guard frozen.isEmpty, unsaved.unsaved().isEmpty else { return false }
        frozen = NSApp.windows.filter(\.isVisible).map { Frozen(window: $0, ignoresMouse: $0.ignoresMouseEvents) }
        for entry in frozen { entry.window?.ignoresMouseEvents = true }
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("windows_frozen.\(frozen.count)")
        #endif
        return true
    }

    /// Gives the frozen windows their clicks back.
    public func restore() {
        afterimage?.cancel()
        for entry in frozen { entry.window?.ignoresMouseEvents = entry.ignoresMouse }
        frozen = []
    }
}
