public import Foundation

/// Where an installed template came from, so `update` can re-fetch it.
public enum OrchestrationInstallSource: Sendable, Hashable, Codable {
    case git(url: String, reference: String?, commit: String?)
    case localPath(String)

    enum CodingKeys: String, CodingKey {
        case kind
        case url
        case reference
        case commit
        case path
    }

    enum Kind: String, Codable {
        case git
        case localPath = "local-path"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindString = try container.decode(String.self, forKey: .kind)
        switch Kind(rawValue: kindString) {
        case .git:
            self = .git(
                url: try container.decode(String.self, forKey: .url),
                reference: try container.decodeIfPresent(String.self, forKey: .reference),
                commit: try container.decodeIfPresent(String.self, forKey: .commit)
            )
        case .localPath:
            self = .localPath(try container.decode(String.self, forKey: .path))
        case nil:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown install source kind '\(kindString)'"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .git(let url, let reference, let commit):
            try container.encode(Kind.git.rawValue, forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(reference, forKey: .reference)
            try container.encodeIfPresent(commit, forKey: .commit)
        case .localPath(let path):
            try container.encode(Kind.localPath.rawValue, forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }

    public var displayName: String {
        switch self {
        case .git(let url, let reference, _):
            if let reference { return "\(url)@\(reference)" }
            return url
        case .localPath(let path):
            return path
        }
    }

    /// Heuristic used by `cmux orchestration install <git-url-or-path>`:
    /// URLs with a scheme, scp-style `git@host:` remotes, and `.git`
    /// suffixes are git; everything else is a local path.
    public static func detect(from argument: String) -> OrchestrationInstallSource {
        let lowered = argument.lowercased()
        let schemes = ["https://", "http://", "ssh://", "git://", "file://"]
        if schemes.contains(where: { lowered.hasPrefix($0) }) || lowered.hasSuffix(".git") {
            return .git(url: argument, reference: nil, commit: nil)
        }
        if !argument.hasPrefix("/"), !argument.hasPrefix("."), !argument.hasPrefix("~"),
           argument.contains("@"), argument.contains(":") {
            return .git(url: argument, reference: nil, commit: nil)
        }
        return .localPath(argument)
    }
}

/// Per-install state stored beside (never inside) the template copy:
/// `~/.cmuxterm/orchestrations/<name>/install.json`.
public struct OrchestrationInstallRecord: Sendable, Hashable, Codable {
    public var schemaVersion: Int
    public var name: String
    public var source: OrchestrationInstallSource
    public var installedAt: Date
    public var updatedAt: Date?
    /// Manifest version captured at install/update time.
    public var templateVersion: String
    /// Answers from the parameter interview, keyed by parameter key.
    public var resolvedParameters: [String: OrchestrationParameterValue]
    /// Set once the user has confirmed the trust summary (scripts, agent
    /// commands, substrate). Cleared on update so changed templates are
    /// re-confirmed before they run again.
    public var trustConfirmedAt: Date?

    public static let currentSchemaVersion = 1
    public static let fileName = "install.json"

    public init(
        schemaVersion: Int = OrchestrationInstallRecord.currentSchemaVersion,
        name: String,
        source: OrchestrationInstallSource,
        installedAt: Date,
        updatedAt: Date? = nil,
        templateVersion: String,
        resolvedParameters: [String: OrchestrationParameterValue] = [:],
        trustConfirmedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.source = source
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.templateVersion = templateVersion
        self.resolvedParameters = resolvedParameters
        self.trustConfirmedAt = trustConfirmedAt
    }
}

/// An installed template: manifest + install record + on-disk location.
public struct InstalledOrchestration: Sendable {
    public var manifest: OrchestrationManifest
    public var record: OrchestrationInstallRecord
    /// Absolute path of the pristine template copy.
    public var templateDirectory: String

    public init(
        manifest: OrchestrationManifest,
        record: OrchestrationInstallRecord,
        templateDirectory: String
    ) {
        self.manifest = manifest
        self.record = record
        self.templateDirectory = templateDirectory
    }
}
