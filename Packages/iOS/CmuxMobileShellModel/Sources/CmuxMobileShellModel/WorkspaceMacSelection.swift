/// The computer scope retained between workspace-screen launches.
public enum WorkspaceMacSelection: Hashable, RawRepresentable, Sendable {
    public static let storageKey = "cmux.workspaces.macSelection"

    case automatic
    case all
    /// A pairing id for saved app instances, or a bare device id for an
    /// unpaired workspace-only computer.
    case machine(String)

    /// Decodes a stored scope without normalizing the computer's exact identity.
    public init?(rawValue: String) {
        switch rawValue {
        case "automatic": self = .automatic
        case "all": self = .all
        default:
            guard rawValue.hasPrefix("machine:") else { return nil }
            let id = String(rawValue.dropFirst("machine:".count))
            guard !id.isEmpty else { return nil }
            self = .machine(id)
        }
    }

    public var rawValue: String {
        switch self {
        case .automatic: "automatic"
        case .all: "all"
        case .machine(let id): "machine:\(id)"
        }
    }
}
