import Foundation

/// Where a server runs: this Mac, or a paired host (a Mac mini, a VM, cmux Cloud) by name.
public nonisolated enum ServerHost: Hashable, Sendable, Codable {
    /// This Mac.
    case local
    /// A paired host, by the name the person knows it by.
    case remote(String)

    /// A stable key for persistence ("local" or "remote:<name>").
    public var key: String {
        switch self {
        case .local: "local"
        case .remote(let name): "remote:\(name)"
        }
    }
}
