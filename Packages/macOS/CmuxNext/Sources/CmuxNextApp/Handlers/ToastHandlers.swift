import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The toasts' own actions (Lawrence 2026-11-12):
/// - `toasts.showHidden` (Settings > Notifications, the palette): every toast kind hidden with a toast's
///   Don't Show Again shows again.
/// - `debug.toastTuning` (DEV and NIGHTLY, `isDebugOnly`): the toast tuning tool. Debug Settings opens on
///   its Toasts section (duration, glass, padding, motion) and the active window shows sample toasts, one of
///   each shape; a knob moved there shows on the next sample (run it again to replay them). Debug Settings'
///   "Copy changed values as JSON" hands the tuned values over to bake in as the defaults.
enum ToastHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bindEffect("toasts.showHidden", effect: { _ in
            CmuxToastCenter.shared.neverShow.showAll()
            return .done
        })
        registry.bind("debug.toastTuning", run: { invocation in
            try context.services.debugSettings.show(selection: .section(CmuxToastTunables.section.id), focus: invocation.allowsViewChange)
            if let window = context.services.windows.active?.window { showSamples(in: window) }
        })
    }

    /// One toast of each shape: a notice (Don't Show Again), an Undo and a long, wrapping message with Details.
    static func showSamples(in window: NSWindow) {
        let center = CmuxToastCenter.shared
        center.show(CmuxToast(id: "debug.toastTuning.notice", message: "Copied the link to “Release notes”"), in: window)
        center.show(CmuxToast(id: "debug.toastTuning.undo", message: "Closed “zsh”", action: .undo()), in: window)
        center.show(CmuxToast(id: "debug.toastTuning.details",
                              message: "Couldn’t save “notes.md” because the disk is full. Free some space and try again.",
                              detail: "fs.no_space: write(2) returned ENOSPC", action: .details("Details")), in: window)
    }
}
