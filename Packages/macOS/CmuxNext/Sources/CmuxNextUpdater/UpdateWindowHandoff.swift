import AppKit
import Foundation
public import CmuxNextDesign
import CmuxNextWakeups

/// Restart to Update is a plain quit and relaunch (Leo, 2026-11-24: "we want to have the restrat to update
/// working as people expect (not the wannabe smooth transition thing) and have it be fast and good"):
/// Sparkle installs, the app quits, the relaunched app restores its windows, workspaces and sessions from
/// the daemon the normal way. Nothing pictures the old windows or holds them on screen across the relaunch.
///
/// What this does is the quit's own look: when Sparkle commits to a relaunch the person asked for
/// (`updaterWillRelaunchApplication`, right before its installer finishes and quits the app), not at the
/// click, every visible window leaves the screen, as a quit's windows do, while the quit saves.
/// An install nobody clicked leaves the windows as they are. A click whose install never reaches the
/// installer (Sparkle gives up after 7 s: "An error occurred while starting the installer") brings them
/// back (``restore()``).
///
/// Windows are ordered out, never faded or made transparent (Leo, 2026-11-24: an alpha step read as "the
/// opacity of the window changed"). They stay alive, so the quit still saves their frames and layout.
/// Pictures of their pages need them on screen (an ordered-out window reads as not shown, and its page
/// draws nothing), so those are saved before the windows leave (``savesBeforeLeaving``): the quit after
/// them used to find no chat on screen and drop every saved page, and the relaunched agent panes came up
/// blank (Leo, 2026-11-24). With unsaved documents nothing changes: the quit asks about them on screen
/// (decision D2).
@MainActor
public final class UpdateWindowHandoff {
    private struct Hidden {
        weak var window: NSWindow?
        var ignoresMouse: Bool
        var animation: NSWindow.AnimationBehavior
    }

    /// Front first (`NSApp.orderedWindows`), so ``restore()`` brings them back in the same order.
    private var hidden: [Hidden] = []
    /// The windows were ordered out (``leaveScreen()``).
    private var orderedOut = false
    private let unsaved: QuitUnsavedRegistry
    /// Saves the pictures of the pages on screen for the next launch (set by the App: the agent chats' and the
    /// browser pages'), as the windows leave for a relaunch and before they do. The quit awaits it rather than
    /// saving again (``UpdaterService/savedForRelaunch``).
    public var savesBeforeLeaving: (@MainActor () async -> Void)?
    /// The relaunch did not happen and the windows came back (``restore()``): what ``savesBeforeLeaving`` paused resumes.
    public var cameBack: (@MainActor () -> Void)?
    /// The longest the windows wait on screen (taking no clicks) for that save.
    static let saveLimit: Duration = .milliseconds(700)
    private weak var updater: UpdaterService?
    private var saveLimitTimer: DemandTimer?

    public init(unsaved: QuitUnsavedRegistry) {
        self.unsaved = unsaved
    }

    /// Installs the updater's hooks: the windows leave as Sparkle commits to the relaunch, not at the click; a failed
    /// install brings them back.
    public func attach(to updater: UpdaterService) {
        // The updater keeps this handoff (it holds nothing of the updater's but this weak reference).
        self.updater = updater
        updater.hidesForRelaunch = { _ = self.hide() }
        updater.installAbandoned = { self.restore() }
    }

    /// Takes every visible window off screen once the pages' pictures are saved; false when it did not
    /// (unsaved documents).
    @discardableResult
    public func hide() -> Bool {
        guard hidden.isEmpty, unsaved.unsaved().isEmpty else { return false }
        hidden = NSApp.orderedWindows.filter(\.isVisible).map {
            Hidden(window: $0, ignoresMouse: $0.ignoresMouseEvents, animation: $0.animationBehavior)
        }
        for entry in hidden { entry.window?.ignoresMouseEvents = true }
        leave(after: saveBeforeLeaving())
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("windows_hidden.\(hidden.count)")
        #endif
        return true
    }

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

    /// Orders every hidden window out in one transaction, with no close animation: the windows leave whole in
    /// one frame, their alpha never changes. They stay alive, so the quit still saves their frames and layout.
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
