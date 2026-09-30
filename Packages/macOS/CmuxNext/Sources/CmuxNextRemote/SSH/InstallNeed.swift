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
        }
    }
}
