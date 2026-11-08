public import AppKit
import CmuxNextCompat

/// Places dialogs with another host (the shared center's, the overlay page, by default) and leaves the window that
/// shows them out of screen capture while they show (the Passwords reveal sheet): cmux's own screen
/// sharing and recorders leave every `.none` window out by id (``CaptureExcludedWindows``), and `NSWindow.sharingType = .none`
/// asks every other capture to skip it, which macOS does not guarantee for another app's ScreenCaptureKit
/// capture (since macOS 15.4). The person still sees them on screen.
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

    public init(inner: any CmuxDialogHosting = CmuxDialogCenter.shared.host) {
        self.inner = inner
    }

    public func show(_ dialog: CmuxDialogPresentation, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {
        inner.show(dialog, in: scope, scopeGone: scopeGone)
        // The window it shows in is the overlay's, known once the host presents it: its view may wait in
        // the source window before, invisible, while the page draws the card.
        dialog.whenPresented { [weak dialog] in
            guard let dialog else { return }
            Self.exclude(dialog)
        }
    }

    private static func exclude(_ dialog: CmuxDialogPresentation) {
        guard let window = dialog.window else { return }
        let key = ObjectIdentifier(window)
        var entry = excluded[key] ?? Excluded(window: window, sharing: window.sharingType, dialogs: [])
        entry.dialogs.insert(ObjectIdentifier(dialog))
        excluded[key] = entry
        window.sharingType = .none
        CaptureExcludedWindows.changed()
    }

    public func hide(_ dialog: CmuxDialogPresentation) {
        // Off the screen now: the overlay's fade-out would draw it after the window is capturable.
        dialog.view?.isHidden = true
        inner.hide(dialog)
        let id = ObjectIdentifier(dialog)
        for (key, var entry) in Self.excluded where entry.dialogs.contains(id) {
            entry.dialogs.remove(id)
            if entry.dialogs.isEmpty {
                entry.window.sharingType = entry.sharing
                CaptureExcludedWindows.changed()
                Self.excluded[key] = nil
            } else {
                Self.excluded[key] = entry
            }
        }
    }
}
