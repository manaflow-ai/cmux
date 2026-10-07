import CmuxMobileWire

/// What a subscriber of `workspace:<host>` receives.
public enum WorkspaceStreamUpdate: Hashable, Sendable {
    case snapshot(SnapshotFrame)
    case event(EventFrame)

    public var frame: MobileFrame {
        switch self {
        case .snapshot(let f): .snapshot(f)
        case .event(let f): .event(f)
        }
    }
}
