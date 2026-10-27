import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign
import UniformTypeIdentifiers
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The app's ``PasswordSecretSurface``. The reveal sheet uses a private dialog center (`debug.dialog`
/// never lists the password) and is left out of screen capture and screen sharing while it shows.
@MainActor
final class NativePasswordSecretSurface: PasswordSecretSurface {
    private let center = CmuxDialogCenter(host: CmuxDialogCaptureExcludedHost())
    private let pasteboard: ConcealedPasteboard

    init(pasteboard: ConcealedPasteboard) {
        self.pasteboard = pasteboard
    }

    func reveal(_ secret: SecretBytes, site: String, username: String, anchor: NSView?) async {
        // SAFETY: as in ConcealedPasteboard.write: the String copies the bytes out of the view SecretBytes lends
        // for the closure, and the view does not escape.
        let text = unsafe secret.withUnsafeBytes { unsafe String(decoding: $0, as: UTF8.self) }
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
        // A panel that drops its reply chose nothing.
        return try? await withOnceContinuation { (continuation: OnceContinuation<URL?, OnceContinuationError>) in
            panel.beginForCmux(in: anchor?.window) { continuation.resume(returning: $0) }
        }
    }
}
