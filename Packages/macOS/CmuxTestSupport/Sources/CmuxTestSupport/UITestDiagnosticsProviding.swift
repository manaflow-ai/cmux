public import Foundation

/// The read-only seam that supplies the live app state the diagnostics
/// recorder needs.
///
/// ``DisplayDiagnosticsUITestRecorder`` owns the byte-faithful payload
/// assembly and file I/O but holds no AppKit / `TerminalController` / portal
/// references; it reads everything through this protocol. The app target
/// conforms (it owns `NSApp`, `TerminalController.shared`, the socket
/// transport, the focused terminal panel, and the portal registry), gathers
/// the values on the main actor, and returns them as a `Sendable`
/// ``UITestDiagnosticsSnapshot``.
///
/// The conformer is responsible for applying each diagnostics section's
/// environment gate (`CMUX_UI_TEST_DISPLAY_RENDER_STATS`,
/// `CMUX_UI_TEST_SOCKET_SANITY`, `CMUX_UI_TEST_PORTAL_STATS`): an ungated
/// section is returned as `nil` so the recorder emits exactly the legacy key
/// set for it.
@MainActor
public protocol UITestDiagnosticsProviding: AnyObject {
    /// Returns the current diagnostics snapshot, with each optional section
    /// already gated by `environment`.
    ///
    /// - Parameter environment: The process environment the diagnostics
    ///   scenario is gated by.
    func currentUITestDiagnosticsSnapshot(environment: [String: String]) -> UITestDiagnosticsSnapshot
}
