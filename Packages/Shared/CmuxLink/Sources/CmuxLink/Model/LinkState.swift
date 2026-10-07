/// The connection state of one link (a3-link.md section 3).
public enum LinkState: Sendable, Hashable {
    case idle
    case connecting(attempt: Int)
    case connected(LinkPath)
    case degraded(LinkPath, DegradedReason)
    /// The transport was lost; channels keep their cursors and resume.
    case reconnecting(attempt: Int, lastPath: LinkPath?)
    case closed(LinkCloseReason)

    public var path: LinkPath? {
        switch self {
        case let .connected(path), let .degraded(path, _): path
        default: nil
        }
    }

    public var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }

    public var isLive: Bool { path != nil }
}
