import Foundation

/// Whether new terminal panes run their shell directly or wrap it in livesh.
///
/// ``livesh`` is a daemon-owned PTY layer that outlives cmux; ``direct`` is the
/// original behavior. Stored under the catalog entry
/// ``TerminalCatalogSection/shellBackend`` as its raw string, matching the
/// legacy `terminalShellBackend` UserDefaults value. Defaults to ``direct`` so
/// existing users see no behavior change until they opt in.
public enum TerminalShellBackend: String, CaseIterable, Sendable, SettingCodable {
    /// Run the shell directly (default).
    case direct
    /// Wrap the shell in the livesh daemon-owned PTY layer.
    case livesh
}
