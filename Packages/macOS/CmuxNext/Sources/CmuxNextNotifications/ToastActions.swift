package import AppKit
package import CmuxNextActions
package import CmuxNextDesign
import CmuxNextDaemonService

/// The toasts' own actions (Lawrence 2026-11-12):
/// - `toasts.showHidden` (Settings > Notifications, the palette): every toast kind hidden with a toast's
///   Don't Show Again shows again.
/// - `debug.toastTuning` (DEV and NIGHTLY, `isDebugOnly`): the toast tuning tool. Debug Settings opens on
///   its Toasts section (duration, glass, padding, motion) and the active window shows sample toasts, one of
///   each shape; a knob moved there shows on the next sample (run it again to replay them). Debug Settings'
///   "Copy changed values as JSON" hands the tuned values over to bake in as the defaults.
///
/// The app injects how Debug Settings opens and which window is active:
///
/// ```swift
/// ToastActions(openTuning: { focus in try debugSettings.show(selection: .section("toasts"), focus: focus) },
///              window: { windows.active?.window }).bind(into: registry)
/// ```
@MainActor
package struct ToastActions {
    private let openTuning: @MainActor (_ focus: Bool) throws -> Void
    private let window: @MainActor () -> NSWindow?
    private let center: CmuxToastCenter

    /// - Parameter openTuning: Opens Debug Settings on its Toasts section; `focus` is the run's
    ///   `allowsViewChange`. Throws an ``ActionFailure`` when this build has no developer tools.
    /// - Parameter window: The window the sample toasts show in; nil shows none.
    /// - Parameter center: The toasts' center (the app's shared one).
    package init(openTuning: @escaping @MainActor (_ focus: Bool) throws -> Void,
                 window: @escaping @MainActor () -> NSWindow?, center: CmuxToastCenter = .shared) {
        self.openTuning = openTuning
        self.window = window
        self.center = center
    }

    /// Binds both actions in `registry`.
    package func bind(into registry: ActionRegistry) {
        let center = center, openTuning = openTuning, window = window
        registry.bindEffect("toasts.showHidden", effect: { _ in
            center.neverShow.showAll()
            return .done
        })
        registry.bindEffect("debug.toastTuning", effect: { invocation in
            do {
                try openTuning(invocation.allowsViewChange)
            } catch {
                return .refused((error as? ActionFailure)?.message ?? String(describing: error))
            }
            if let window = window() { Self.showSamples(in: window, center: center) }
            return .done
        })
    }

    /// One toast of each shape: a notice (Don't Show Again), an Undo and a long, wrapping message with
    /// Details. English developer text, as every Debug Settings sample is.
    static func showSamples(in window: NSWindow, center: CmuxToastCenter) {
        center.show(CmuxToast(id: "debug.toastTuning.notice", message: "Copied the link to “Release notes”"), in: window)
        center.show(CmuxToast(id: "debug.toastTuning.undo", message: "Closed “zsh”", action: .undo()), in: window)
        center.show(CmuxToast(id: "debug.toastTuning.details",
                              message: "Couldn’t save “notes.md” because the disk is full. Free some space and try again.",
                              detail: "fs.no_space: write(2) returned ENOSPC", action: .details("Details")), in: window)
    }
}
