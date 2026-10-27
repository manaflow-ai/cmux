public import AppKit

/// What ``CEFPlatformPasskeys`` asks of macOS: iCloud Keychain through AuthenticationServices in the
/// app (``ChromiumSystemPasskeys``); tests pass a recorder.
@MainActor
protocol ChromiumPlatformPasskeySystem: AnyObject {
    /// cmux can run iCloud Keychain itself: it carries the browser passkey entitlement.
    var isAvailable: Bool { get }
    var permission: ChromiumPasskeyPermission { get }
    /// Asks the person for the passkey listing permission once (the system prompt); the state after.
    func requestPermission() async -> ChromiumPasskeyPermission
    func credentials(forRelyingParty rpID: String) async -> [ChromiumPlatformCredential]
    /// Shows the system sheet for `ceremony` over `anchor`, the pane's own window (K10).
    func start(_ ceremony: ChromiumPasskeyCeremony, anchor: NSWindow) -> any ChromiumPasskeyRun
}

/// One running ceremony.
@MainActor
protocol ChromiumPasskeyRun: AnyObject {
    /// How it ended; after ``cancel()``, the system's cancellation error.
    func result() async -> ChromiumPasskeyCeremonyResult
    /// Closes the sheet (Chromium dropped the request).
    func cancel()
}
