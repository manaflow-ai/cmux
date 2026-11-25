import AppKit
public import Foundation
public import CmuxNextDesign
import CmuxNextWakeups

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
/// saves their frames and layout), and an install that fails brings them
/// back. Pictures of their pages need them on screen (an ordered-out window
/// reads as not shown, and its page draws nothing), so those are saved
/// before the windows leave (``savesBeforeLeaving``): the quit after them
/// used to find no chat on screen and drop every saved page, and the
/// relaunched agent panes came up blank (Leo, 2026-11-24). With unsaved documents nothing changes: the quit asks about
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
    /// Saves the pictures of the pages on screen for the next launch (set by the App: the agent chats' and the
    /// browser pages'), as the windows leave for a relaunch and before they do. The quit awaits it rather than
    /// saving again (``UpdaterService/savedForRelaunch``).
    public var savesBeforeLeaving: (@MainActor () async -> Void)?
    /// The relaunch did not happen and the windows came back (``restore()``): what ``savesBeforeLeaving`` paused resumes.
    public var cameBack: (@MainActor () -> Void)?
    /// The longest the windows wait on screen (under the afterimage, taking no clicks) for that save.
    static let saveLimit: Duration = .milliseconds(700)
    private weak var updater: UpdaterService?
    private var saveLimitTimer: DemandTimer?

    public init(unsaved: QuitUnsavedRegistry, stateDirectory: URL? = nil) {
        self.unsaved = unsaved
        afterimage = stateDirectory.map { RelaunchAfterimage(stateDirectory: $0) }
    }

    /// Installs the updater's hooks: the windows leave as Sparkle commits to the relaunch, not at the click; a failed
    /// install brings them back. The quit waits for the pictures (``UpdaterService/afterimage``).
    public func attach(to updater: UpdaterService) {
        // The updater keeps this handoff (it holds nothing of the updater's but this weak reference).
        self.updater = updater
        updater.hidesForRelaunch = { _ = self.hide() }
        updater.installAbandoned = { self.restore() }
        updater.afterimage = afterimage
    }

    /// A relaunch is decided (every path: ``UpdaterService/willRelaunch``): the windows are pictured for the afterimage,
    /// unless the quit will ask about unsaved documents (that sheet stays in view).
    public func relaunchDecided() {
        guard unsaved.unsaved().isEmpty else { return }
        afterimage?.begin(activates: NSApp.isActive, status: UpdaterStrings.revertRestarting) // "Restarting…", with a spinner
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
            // With pictures coming, the windows wait for them (about 100 to 250 ms, the quit's saves run meanwhile),
            // and for the pictures of their pages, which an ordered-out window can no longer give.
            let saved = saveBeforeLeaving()
            let leave: @MainActor @Sendable () -> Void = { [weak self] in self?.leave(after: saved) }
            if let afterimage, afterimage.isActive { afterimage.whenShown(leave) } else { leave() }
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("windows_\(Self.mode == .hide ? "hidden" : "frozen").\(hidden.count)")
        #endif
        return true
    }

    /// Orders every hidden window out in one transaction, with no close animation: the windows leave
    /// whole in one frame (behind the afterimage when it is up), their alpha never changes. They stay
    /// alive, so the quit still saves their frames and layout.
    /// Starts ``savesBeforeLeaving`` once per relaunch; the quit awaits the same task.
    private func saveBeforeLeaving() -> Task<Void, Never>? {
        guard let save = savesBeforeLeaving else { return nil }
        // task-owner: one save of the pages on screen per relaunch; the quit awaits it (UpdaterService.savedForRelaunch).
        let task = Task { await save() }
        updater?.savedForRelaunch = task
        return task
    }

    /// Orders the windows out once `save` ended, or at ``saveLimit``.
    private func leave(after save: Task<Void, Never>?) {
        guard let save, !hidden.isEmpty else { return leaveScreen() }
        let limit = DemandTimer(owner: "UpdateWindowHandoff.saveLimit")
        saveLimitTimer = limit
        limit.schedule(after: Self.saveLimit) { @MainActor [weak self] in self?.leaveScreen() }
        // task-owner: waits on the relaunch's one save (bounded by the timer above); ends with it.
        Task { [weak self] in
            await save.value
            self?.saveLimitTimer?.cancel()
            self?.leaveScreen()
        }
    }

    private func leaveScreen() {
        guard !hidden.isEmpty, !orderedOut else { return }
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
        saveLimitTimer?.cancel()
        saveLimitTimer = nil
        if updater?.savedForRelaunch != nil {
            updater?.savedForRelaunch = nil
            cameBack?()
        }
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
