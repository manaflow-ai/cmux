import Foundation

/// How a secret entered the vault, kept for display ("Imported from .env").
///
/// Encodes as its ``wireValue`` (`manual`, `dotenv:<file>`, `shell`, `gh`).
public enum CloudSecretSource: Hashable, Codable, Sendable {
    /// Typed into a prompt or secure field.
    case manual
    /// Imported from a dotenv file; the payload is the file name, never its contents.
    case dotenv(String)
    /// Imported from this Mac's shell environment.
    case shell
    /// Imported from the GitHub CLI's stored token.
    case ghCLI

    /// `manual`, `dotenv:<file>`, `shell` or `gh`.
    public var wireValue: String {
        switch self {
        case .manual: return "manual"
        case .dotenv(let fileName): return "dotenv:\(fileName)"
        case .shell: return "shell"
        case .ghCLI: return "gh"
        }
    }

    /// Parses a ``wireValue``; anything unknown is `nil`.
    public init?(wireValue: String) {
        switch wireValue {
        case "manual": self = .manual
        case "shell": self = .shell
        case "gh": self = .ghCLI
        default:
            guard wireValue.hasPrefix("dotenv:") else { return nil }
            self = .dotenv(String(wireValue.dropFirst("dotenv:".count)))
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // A source written by a newer build is display-only metadata: degrade, never fail the vault.
        self = CloudSecretSource(wireValue: raw) ?? .manual
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
