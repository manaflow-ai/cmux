/// Why a cmux Remote request did not run.
public enum CmuxRemoteError: Error, CustomStringConvertible {
    case unavailable
    case notTheHost
    case refused(String)

    public var description: String {
        switch self {
        case .unavailable: "this cmux has no cmux Remote (the daemon does not run it)"
        case .notTheHost: "the app socket's peer is not cmux Remote"
        case let .refused(message): message
        }
    }
}
