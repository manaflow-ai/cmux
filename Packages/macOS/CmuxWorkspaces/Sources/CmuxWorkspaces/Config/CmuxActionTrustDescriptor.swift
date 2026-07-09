import CryptoKit
import Foundation

/// A stable description of a project-local config action (workspace command,
/// terminal command, or notification hook) used to decide whether the user has
/// trusted it. Its ``fingerprint`` is the SHA-256 of the sorted-keys JSON
/// encoding of these fields, which is the on-disk identity stored in the trust
/// store; the field set and encoding must stay byte-identical to preserve every
/// previously granted trust.
public struct CmuxActionTrustDescriptor: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var actionID: String
    public var kind: String
    public var command: String?
    public var target: String?
    public var workspaceCommand: CmuxCommandDefinition?
    public var configPath: String?
    public var projectRoot: String?
    public var iconFingerprint: String?

    public init(
        schemaVersion: Int = 1,
        actionID: String,
        kind: String,
        command: String? = nil,
        target: String? = nil,
        workspaceCommand: CmuxCommandDefinition? = nil,
        configPath: String? = nil,
        projectRoot: String? = nil,
        iconFingerprint: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.actionID = actionID
        self.kind = kind
        self.command = command
        self.target = target
        self.workspaceCommand = workspaceCommand
        self.configPath = configPath
        self.projectRoot = projectRoot
        self.iconFingerprint = iconFingerprint
    }

    /// The SHA-256 hex of this descriptor's sorted-keys JSON encoding, used as the
    /// trust-store identity. Stable across runs for the same descriptor fields.
    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return Self.sha256Hex(data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
