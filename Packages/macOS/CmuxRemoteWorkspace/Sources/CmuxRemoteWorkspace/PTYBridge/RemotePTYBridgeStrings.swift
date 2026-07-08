/// App-resolved user-facing strings for PTY-bridge attach failures.
///
/// The package maps daemon errors to these strings (the matching logic is
/// wire-pinned in ``RemotePTYBridgeServer``), but the strings themselves
/// resolve in the app target so `String(localized:)` binds to the app
/// bundle's localization tables (the package never localizes).
public protocol RemotePTYBridgeStrings: Sendable {
    /// Shown when the daemon lacks the persistent-PTY capability family.
    var missingPersistentPTYCapability: String { get }
    /// Shown when the persistent PTY session has already ended.
    var sessionEnded: String { get }
    /// Shown when the daemon reports its PTY input queue is full.
    var inputBackedUp: String { get }
    /// Shown when the daemon does not answer the attach in time.
    var daemonTimeout: String { get }
    /// Wraps the daemon's PTY-allocation diagnostic (the dynamic `message`
    /// names the failing device and cause; see
    /// https://github.com/manaflow-ai/cmux/issues/5185).
    func allocationDiagnostic(_ message: String) -> String
    /// Generic attach-failure fallback.
    var attachFailed: String { get }
}
