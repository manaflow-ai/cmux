public import Foundation

/// A persisted surface-resume approval: the canonicalized command prefix, its
/// working directory and environment constraints, the recorded
/// ``SurfaceResumeApprovalPolicy``, and an optional HMAC signature that binds
/// the record to a per-machine secret.
///
/// The store matches a candidate binding against stored records, signs records
/// on write, and validates signatures on read. The Codable shape is the wire
/// format persisted by the surface-resume approval store, so field names and
/// `version` are stable.
public struct SurfaceResumeApprovalRecord: Codable, Equatable, Identifiable, Sendable {
    /// Wire-format version of this record. Always `1`.
    public var version: Int
    /// Stable identifier for this approval record.
    public var id: String
    /// Optional human-readable label for the approval.
    public var name: String?
    /// The canonicalized argv prefix the binding's command must begin with.
    public var commandPrefix: [String]
    /// The normalized working directory the binding must match, if constrained.
    public var cwd: String?
    /// The environment values the binding must match exactly, if constrained.
    public var environment: [String: String]?
    /// The environment variable names associated with this approval.
    public var environmentKeys: [String]
    /// The binding source this approval was created for, for example `cli`.
    public var source: String?
    /// The recorded approval disposition.
    public var policy: SurfaceResumeApprovalPolicy
    /// Unix timestamp when the record was created.
    public var createdAt: TimeInterval
    /// Unix timestamp when the record was last updated.
    public var updatedAt: TimeInterval
    /// Unix timestamp when the record was last used to approve a resume, if ever.
    public var lastUsedAt: TimeInterval?
    /// Base64 HMAC-SHA256 signature over the record's signing payload, if signed.
    public var signature: String?

    /// Creates an approval record, normalizing the name, command prefix, working
    /// directory, environment, and environment keys exactly as the persisted
    /// store does.
    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String? = nil,
        commandPrefix: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        environmentKeys: [String] = [],
        source: String? = nil,
        policy: SurfaceResumeApprovalPolicy,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        lastUsedAt: TimeInterval? = nil,
        signature: String? = nil
    ) {
        self.version = 1
        self.id = id
        self.name = Self.normalized(name)
        self.commandPrefix = commandPrefix.filter { !$0.isEmpty }
        self.cwd = cwd.flatMap { $0.surfaceResumeNormalizedCWD }
        self.environment = Self.normalizedEnvironment(environment)
        self.environmentKeys = Self.normalizedEnvironmentKeys(environmentKeys, environment: self.environment)
        self.source = Self.normalized(source)
        self.policy = policy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.signature = Self.normalized(signature)
    }

    /// The command prefix rendered as a shell-quoted, space-joined string.
    public var commandPrefixText: String {
        commandPrefix.map(\.surfaceResumeShellQuoted).joined(separator: " ")
    }

    /// Whether this record's command prefix, working directory, and environment
    /// constraints all match the given binding.
    public func matches(_ binding: any WorkspaceSurfaceResumeBinding) -> Bool {
        guard !commandPrefix.isEmpty,
              let tokens = binding.command.surfaceResumeCommandTokens(),
              tokens.count >= commandPrefix.count,
              Array(tokens.prefix(commandPrefix.count)) == commandPrefix else {
            return false
        }
        if let cwd {
            guard binding.cwd.flatMap({ $0.surfaceResumeNormalizedCWD }) == cwd else {
                return false
            }
        }
        let bindingEnvironment = binding.environment ?? [:]
        guard let environment, !environment.isEmpty else {
            return bindingEnvironment.isEmpty
        }
        return bindingEnvironment == environment
    }

    func signingPayloadData() -> Data {
        let encodedPrefix = commandPrefix
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ",")
        let encodedEnvironmentKeys = environmentKeys
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ",")
        let encodedEnvironment = (environment ?? [:])
            .keys
            .sorted()
            .map { key in
                let value = environment?[key] ?? ""
                return "\(Data(key.utf8).base64EncodedString())=\(Data(value.utf8).base64EncodedString())"
            }
            .joined(separator: ",")
        let fields = [
            "version=\(version)",
            "id=\(id)",
            "name=\(name.map { Data($0.utf8).base64EncodedString() } ?? "")",
            "commandPrefix=\(encodedPrefix)",
            "cwd=\(cwd.map { Data($0.utf8).base64EncodedString() } ?? "")",
            "environment=\(encodedEnvironment)",
            "environmentKeys=\(encodedEnvironmentKeys)",
            "source=\(source.map { Data($0.utf8).base64EncodedString() } ?? "")",
            "policy=\(policy.rawValue)",
            "createdAt=\(createdAt)",
            "updatedAt=\(updatedAt)",
            "lastUsedAt=\(lastUsedAt.map { String($0) } ?? "")",
        ]
        return fields.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    /// Returns a copy of this record signed with the given secret.
    public func signed(secret: Data) -> SurfaceResumeApprovalRecord {
        var copy = self
        copy.signature = copy.signingPayloadData().surfaceResumeApprovalSignature(secret: secret)
        return copy
    }

    /// Whether this record carries a signature matching the given secret.
    public func hasValidSignature(secret: Data) -> Bool {
        guard let signature else { return false }
        return signingPayloadData().surfaceResumeApprovalSignature(secret: secret) == signature
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private static func normalizedEnvironment(_ environment: [String: String]?) -> [String: String]? {
        guard let environment else { return nil }
        let normalized = environment.reduce(into: [String: String]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            guard isSafeEnvironmentValue(item.value) else { return }
            result[key] = item.value
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func isSafeEnvironmentValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func normalizedEnvironmentKeys(
        _ environmentKeys: [String],
        environment: [String: String]?
    ) -> [String] {
        let explicitKeys = environmentKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let environmentDerivedKeys: [String] = environment.map { Array($0.keys) } ?? []
        return Array(Set(explicitKeys + environmentDerivedKeys)).sorted()
    }
}
