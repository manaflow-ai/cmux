/// Why a cmux Computer Use request did not run.
public enum CmuxHelperError: Error, CustomStringConvertible {
    case unavailable
    case configurationTimeout
    case notTheHost
    case refused(String)

    public var description: String {
        switch self {
        case .unavailable: "this cmux has no cmux Computer Use (the daemon does not run it)"
        case .configurationTimeout: "device_hub_configuration_timeout"
        case .notTheHost: "the app socket's peer is not cmux Computer Use"
        case let .refused(message): message
        }
    }
}
