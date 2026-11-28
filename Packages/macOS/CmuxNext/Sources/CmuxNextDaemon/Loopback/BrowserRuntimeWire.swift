import Foundation

// Wire shapes of cmux-tui `browser-runtime-v1` (cmux-tui/spec/commands.md,
// "Browser runtimes"; cx-2cob slice 2).

enum BrowserRuntimeRequest {
    static let capability = DaemonCapabilities.shared.browserRuntime
}

struct BrowserRuntimeStatusRequest: DaemonRequest {
    typealias Response = BrowserRuntimeStatus
    static let command = "browser-runtime-status"
    static let requiredCapability: String? = BrowserRuntimeRequest.capability
}

/// The machine's installed browser host.
public struct BrowserRuntimeStatus: Decodable, Sendable, Equatable {
    /// The installed version, nil when none is installed.
    public var installed: String?
    /// `<os>-<arch>` of the machine (`macos-aarch64`, `linux-x86_64`).
    public var platform: String

    public init(installed: String?, platform: String) {
        self.installed = installed
        self.platform = platform
    }
}

struct BrowserRuntimeStartRequest: DaemonRequest {
    typealias Response = BrowserRuntime
    static let command = "browser-runtime-start"
    static let requiredCapability: String? = BrowserRuntimeRequest.capability
    var url: String?
}

/// A browser host the daemon started for this app. `secret` is the host's
/// `cmux.rd/1` hello token: keep it in memory only.
public struct BrowserRuntime: Decodable, Sendable {
    public var runtime: UInt64
    public var port: UInt16
    public var secret: String
    public var installed: String
}

struct BrowserRuntimeStopRequest: DaemonRequest {
    typealias Response = BrowserRuntimeStopped
    static let command = "browser-runtime-stop"
    static let requiredCapability: String? = BrowserRuntimeRequest.capability
    var runtime: UInt64
}

struct BrowserRuntimeStopped: Decodable, Sendable {
    var stopped: Bool
}

/// Why the machine's browser cannot start.
public enum BrowserRuntimeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The machine's cmux-tui is too old for browser runtimes (update it).
    case unsupported
    case notInstalled
    /// The host exited or did not listen; the detail ends with its log.
    case startFailed(String)
    case limit
    /// No connection to the machine's daemon.
    case unavailable(String)
    case other(String)

    public var description: String {
        switch self {
        case .unsupported: "the machine's cmux-tui does not support browser tabs"
        case .notInstalled: "the browser is not installed on the machine"
        case .startFailed(let detail): detail
        case .limit: "too many browsers run on the machine"
        case .unavailable(let detail): "not connected to the machine: \(detail)"
        case .other(let detail): detail
        }
    }

    static func from(_ error: any Error) -> BrowserRuntimeError {
        if let error = error as? BrowserRuntimeError { return error }
        if let error = error as? LoopbackForwardError {
            switch error {
            case .unsupported: return .unsupported
            case .unavailable(let detail): return .unavailable(detail)
            default: return .other(error.description)
            }
        }
        guard let error = error as? DaemonError else { return .other(String(describing: error)) }
        switch error {
        case .command(_, let message, let code, _, _):
            switch code {
            case "browser-runtime.not-enabled": return .unsupported
            case "browser-runtime.not-installed": return .notInstalled
            case "browser-runtime.start-failed": return .startFailed(message)
            case "browser-runtime.limit": return .limit
            default: return .other(message)
            }
        default: return .unavailable(error.description)
        }
    }
}
