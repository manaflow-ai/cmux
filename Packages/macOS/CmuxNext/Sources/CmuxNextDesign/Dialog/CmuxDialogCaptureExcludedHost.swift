public import AppKit

/// Places dialogs with another host (the overlay host by default) and leaves the window that
/// shows them out of screen capture and screen sharing (`NSWindow.sharingType = .none`) while
/// they show: a screenshot, a recording, screen sharing or an agent's capture never contains
/// what they show (the Passwords reveal sheet). The person still sees them on screen.
///
/// Every instance shares one record per window (one overlay panel serves every dialog of a
/// window), so the window gets its own sharing type back only when the last excluded dialog on
/// it hides, whichever host showed it. A hidden dialog leaves the screen at once, with no
/// fade-out, so it is never drawn after its window becomes capturable again.
@MainActor
public final class CmuxDialogCaptureExcludedHost: CmuxDialogHosting {
    private struct Excluded {
        let window: NSWindow
        let sharing: NSWindow.SharingType
        var dialogs: Set<ObjectIdentifier>
    }

    private static var excluded: [ObjectIdentifier: Excluded] = [:]
    private let inner: any CmuxDialogHosting

    public init(inner: any CmuxDialogHosting = CmuxDialogOverlayHost()) {
        self.inner = inner
    }

    public func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {
        inner.show(dialog, in: scope, scopeGone: scopeGone)
        guard let window = dialog.window else { return }
        let key = ObjectIdentifier(window)
        var entry = Self.excluded[key] ?? Excluded(window: window, sharing: window.sharingType, dialogs: [])
        entry.dialogs.insert(ObjectIdentifier(dialog))
        Self.excluded[key] = entry
        window.sharingType = .none
    }

    public func dialogDidUpdate(_ dialog: CmuxDialogView) {
        inner.dialogDidUpdate(dialog)
    }

    public func hide(_ dialog: CmuxDialogView) {
        // Off the screen now: the overlay's fade-out would draw it after the window is capturable.
        dialog.isHidden = true
        inner.hide(dialog)
        let id = ObjectIdentifier(dialog)
        for (key, var entry) in Self.excluded where entry.dialogs.contains(id) {
            entry.dialogs.remove(id)
            if entry.dialogs.isEmpty {
                entry.window.sharingType = entry.sharing
                Self.excluded[key] = nil
            } else {
                Self.excluded[key] = entry
            }
        }
    }
}
