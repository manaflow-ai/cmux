enum DockConfigOrigin: Hashable, Sendable {
    case local
    case remote(identity: String, displayTarget: String)

    var identity: String {
        switch self {
        case .local:
            return "local"
        case .remote(let identity, _):
            return "remote:\(identity)"
        }
    }

    func displayPath(_ path: String) -> String {
        switch self {
        case .local:
            return path
        case .remote(_, let displayTarget):
            return "\(displayTarget):\(path)"
        }
    }
}
