import Foundation

/// A device-management policy cmux honors when an administrator forces it
/// through a macOS configuration profile (MDM "Custom Settings" payload).
///
/// The raw value is the preference key an administrator sets in the
/// ``ManagedDevicePolicy/releasePayloadDomain`` preference domain. Policy
/// keys are deliberately separate from the user-facing settings catalog:
/// a managed policy is tier-0 — it wins over environment variables, user
/// `UserDefaults`, `cmux.json` imports, and built-in defaults — and it can
/// never be changed from inside the app.
public enum ManagedDevicePolicyKey: String, CaseIterable, Sendable {
    /// Disables every embedded-browser surface: browser panes and tabs,
    /// terminal-link interception, and browser creation from automation,
    /// layouts, and session restore.
    case disableEmbeddedBrowser = "DisableEmbeddedBrowser"

    /// Disables the Mac acting as a remote view/control host for the cmux
    /// iOS companion app: the Iroh host runtime, the legacy TCP pairing
    /// listener, connection admission, and device pairing.
    case disableRemoteControl = "DisableRemoteControl"

    /// Restricts embedded-browser top-level navigations to the administrator's
    /// URL patterns. An empty forced array denies every external web origin
    /// while preserving local `file:` documents and cmux-owned internal
    /// documents.
    case browserURLAllowlist = "BrowserURLAllowlist"
}
