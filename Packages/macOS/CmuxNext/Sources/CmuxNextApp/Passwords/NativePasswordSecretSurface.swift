import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign
import UniformTypeIdentifiers

/// The app's ``PasswordSecretSurface``. The reveal sheet uses a private dialog center, so the
/// DEBUG `debug.dialog` verb (which reads `CmuxDialogCenter.shared`) never lists the password, and
/// its window is left out of screen capture while the password shows.
@MainActor
final class NativePasswordSecretSurface: PasswordSecretSurface {
    private let center = CmuxDialogCenter(host: CaptureExcludedDialogHost())
    private let pasteboard: ConcealedPasteboard

    init(pasteboard: ConcealedPasteboard = ConcealedPasteboard()) {
        self.pasteboard = pasteboard
    }

    func reveal(_ secret: SecretBytes, site: String, username: String, anchor: NSView?) async {
        let text = secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        let spec = CmuxDialogSpec(
            title: site, lines: username.isEmpty ? [] : [username], fields: [.preview(text)],
            buttons: [CmuxDialogButton(id: "copy", title: PasswordStrings.copyPassword), .ok(PasswordStrings.done)],
            identifier: "cmux.passwords.reveal")
        let scope: CmuxDialogScope = anchor?.window.map { .window($0) } ?? .app
        if await center.present(spec, in: scope).button == "copy" { pasteboard.write(secret) }
    }

    func copy(_ secret: SecretBytes) {
        pasteboard.write(secret)
    }

    func exportDestination(profileName: String, anchor: NSView?) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PasswordStrings.exportFileName(profileName)
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            panel.beginForCmux(in: anchor?.window) { continuation.resume(returning: $0) }
        }
    }
}

/// Shows dialogs on the app's overlay host and leaves their window out of screen capture and
/// screen sharing (`NSWindow.sharingType = .none`) while they show, so a recording, a screenshot
/// or an agent's screen capture never contains a revealed password. The window's own sharing
/// type comes back when the dialog hides.
@MainActor
final class CaptureExcludedDialogHost: CmuxDialogHosting {
    private let inner: any CmuxDialogHosting
    private var restore: [ObjectIdentifier: (window: NSWindow, sharing: NSWindow.SharingType)] = [:]

    init(inner: any CmuxDialogHosting = CmuxDialogOverlayHost()) {
        self.inner = inner
    }

    func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {
        inner.show(dialog, in: scope, scopeGone: scopeGone)
        guard let window = dialog.window else { return }
        restore[ObjectIdentifier(dialog)] = (window, window.sharingType)
        window.sharingType = .none
    }

    func hide(_ dialog: CmuxDialogView) {
        if let previous = restore.removeValue(forKey: ObjectIdentifier(dialog)) {
            previous.window.sharingType = previous.sharing
        }
        inner.hide(dialog)
    }
}
