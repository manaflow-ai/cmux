public import Foundation

/// A JSON parameter value of a relayed request.
public indirect enum RelayValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([RelayValue])
    case object([String: RelayValue])
    case null
}

/// What a remote machine may make this Mac do.
public struct RemoteRelayPolicy: Sendable {
    public struct Ownership: Sendable {
        public var workspaces: Set<String>
        public var surfaces: Set<String>
        public var tabs: Set<String>
        public init(workspaces: Set<String> = [], surfaces: Set<String> = [], tabs: Set<String> = []) {
            self.workspaces = workspaces
            self.surfaces = surfaces
            self.tabs = tabs
        }
    }

    public enum Denial: Hashable, Sendable {
        case notAllowlisted(String)
        case commandParam(String)
        case unownedTarget(String, String)
    }

    public enum Decision: Hashable, Sendable {
        case allow
        case deny(Denial)
    }

    public let allowed: Set<String>

    public static let denyAll = RemoteRelayPolicy(allowed: [])

    public init(allowed: Set<String>) {
        self.allowed = allowed
    }

    public func decide(method: String, params: [String: RelayValue], owned: Ownership) -> Decision { .allow }

    public static func remoteBrowserURL(_ text: String?) -> URL? { text.flatMap(URL.init(string:)) }
}
