import Foundation

/// Whether a machine's cmux-tui must be installed or replaced before the
/// app can attach.
public enum InstallNeed: Hashable, Sendable {
    case none
    case missing
    case unrunnable(String)
    case protocolMismatch(remote: Int, local: Int)
    case wrongApp(String)
    case unsupportedPlatform
    /// The bundled cmux-tui's SSH bootstrap refused the machine's cmux-tui
    /// with a typed reason (the link exits; see ``RemoteRefusal``).
    case refused(RemoteRefusal)

    /// `localProtocol` is the bundled cmux-tui's `remote_protocol`: the
    /// link's framing must match on both ends. Daemon features are judged
    /// later from the daemon's own `identify` (DaemonCompatibility).
    public static func assess(_ report: SSHProbeReport, localProtocol: Int) -> InstallNeed {
        guard report.platform != nil else { return .unsupportedPlatform }
        switch report.binary {
        case .missing: return .missing
        case .unrunnable(let reason): return .unrunnable(reason)
        case .installed(let probe):
            guard probe.app == "cmux-tui" else { return .wrongApp(probe.app) }
            guard probe.remoteProtocol == localProtocol else { return .protocolMismatch(remote: probe.remoteProtocol, local: localProtocol) }
            return .none
        }
    }

    /// The app can fix it by installing the pinned build.
    public var canInstall: Bool {
        switch self {
        case .none, .unsupportedPlatform: false
        case .missing, .unrunnable, .protocolMismatch, .wrongApp: true
        // A newer machine needs a newer app; installing would downgrade it.
        case .refused(let refusal): refusal != .protocolNewer
        }
    }
}

/// Why the bundled cmux-tui refused to link to a machine's cmux-tui. Rust
/// owns the rule (cmux-remote `Incompatibility::code`, and `remote-link`'s
/// unknown-option error) and ends its error text with `[code]`; the app
/// only reads the code. The user-facing text for each case lives in one
/// table, `RemoteStrings.refusalText`.
public enum RemoteRefusal: String, CaseIterable, Hashable, Sendable {
    /// The machine's cmux-tui is older than this connection needs (another
    /// link protocol, or a link flag it does not know, such as `--mux-socket`).
    case protocolOlder = "remote-protocol-older"
    /// The machine's cmux-tui speaks a newer link protocol than this app.
    case protocolNewer = "remote-protocol-newer"
    /// Another program is at the cmux-tui path.
    case wrongApp = "remote-wrong-app"
    /// An installing client found another release.
    case distributionMismatch = "remote-distribution-mismatch"
    /// An installing client with an unpublished build found another build.
    case buildMismatch = "remote-build-mismatch"

    /// The refusal whose `[code]` is in a link's error output (Rust emits at
    /// most one), or nil when it has none.
    public static func parse(_ output: String) -> RemoteRefusal? {
        allCases.first { output.contains("[\($0.rawValue)]") }
    }
}
