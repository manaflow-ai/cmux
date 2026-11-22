/// Why a cmux Helper request did not run.
public enum CmuxHelperError: Error, CustomStringConvertible {
    case unavailable
    case refused(String)

    public var description: String {
        switch self {
        case .unavailable: "the daemon does not serve cmux Helper (helper-v1)"
        case let .refused(message): message
        }
    }
}
