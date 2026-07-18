import Foundation

/// A validated request for cmux to monitor one Codex turn in-process.
public struct CodexTranscriptMonitorRequest: Sendable, Equatable {
    /// The fixed sidecar kind accepted by `agent.sidecar.start`.
    public static let sidecarKind = "codex_transcript_monitor"

    /// The Codex session identity.
    public let sessionID: String

    /// The Codex turn identity, when supplied by the hook.
    public let turnID: String?

    /// The transcript path supplied by Codex, when already known.
    public let transcriptPath: String?

    /// The working directory associated with the turn.
    public let workingDirectory: String?

    /// The workspace that owned the resolved surface when the prompt arrived.
    public let workspaceID: String

    /// The resolved surface identity, when available.
    public let surfaceID: String?

    /// The lifecycle lease written by the prompt hook.
    public let leasePath: String?

    /// The hook process's home directory.
    public let homeDirectory: String?

    /// The hook process's Codex configuration directory.
    public let codexHome: String?

    /// The hook process's cmux state directory override.
    public let stateDirectory: String?

    /// Creates a validated transcript-monitor request.
    ///
    /// - Parameters:
    ///   - sessionID: The Codex session identity.
    ///   - turnID: The Codex turn identity.
    ///   - transcriptPath: The known transcript path.
    ///   - workingDirectory: The turn's working directory.
    ///   - workspaceID: The resolved workspace identity.
    ///   - surfaceID: The resolved surface identity.
    ///   - leasePath: The lifecycle lease path.
    ///   - homeDirectory: The hook process's home directory.
    ///   - codexHome: The hook process's Codex home directory.
    ///   - stateDirectory: The hook process's cmux state directory.
    public init?(
        sessionID: String,
        turnID: String?,
        transcriptPath: String?,
        workingDirectory: String?,
        workspaceID: String,
        surfaceID: String?,
        leasePath: String?,
        homeDirectory: String?,
        codexHome: String?,
        stateDirectory: String?
    ) {
        guard let sessionID = Self.identity(sessionID, maximumBytes: 512),
              let workspaceID = Self.identity(workspaceID, maximumBytes: 128),
              UUID(uuidString: workspaceID) != nil else {
            return nil
        }
        let surfaceID = Self.optionalIdentity(surfaceID, maximumBytes: 128)
        if let surfaceID, UUID(uuidString: surfaceID) == nil { return nil }
        self.sessionID = sessionID
        self.turnID = Self.optionalIdentity(turnID, maximumBytes: 512)
        self.transcriptPath = Self.optionalPath(transcriptPath)
        self.workingDirectory = Self.optionalPath(workingDirectory)
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.leasePath = Self.optionalPath(leasePath)
        self.homeDirectory = Self.optionalPath(homeDirectory)
        self.codexHome = Self.optionalPath(codexHome)
        self.stateDirectory = Self.optionalPath(stateDirectory)
    }

    /// Creates a request from the fixed `agent.sidecar.start` wire schema.
    ///
    /// - Parameter socketParameters: The decoded v2 socket parameters.
    public init?(socketParameters: [String: Any]) {
        guard socketParameters["kind"] as? String == Self.sidecarKind,
              let sessionID = socketParameters["session_id"] as? String,
              let workspaceID = socketParameters["workspace_id"] as? String else {
            return nil
        }
        let environment = socketParameters["environment"] as? [String: Any] ?? [:]
        self.init(
            sessionID: sessionID,
            turnID: socketParameters["turn_id"] as? String,
            transcriptPath: socketParameters["transcript_path"] as? String,
            workingDirectory: socketParameters["cwd"] as? String,
            workspaceID: workspaceID,
            surfaceID: socketParameters["surface_id"] as? String,
            leasePath: socketParameters["lease_path"] as? String,
            homeDirectory: environment["HOME"] as? String,
            codexHome: environment["CODEX_HOME"] as? String,
            stateDirectory: environment["CMUX_AGENT_HOOK_STATE_DIR"] as? String
        )
    }

    /// Encodes the fixed request schema accepted by `agent.sidecar.start`.
    public var socketParameters: [String: Any] {
        var result: [String: Any] = [
            "kind": Self.sidecarKind,
            "session_id": sessionID,
            "workspace_id": workspaceID,
        ]
        if let turnID { result["turn_id"] = turnID }
        if let transcriptPath { result["transcript_path"] = transcriptPath }
        if let workingDirectory { result["cwd"] = workingDirectory }
        if let surfaceID { result["surface_id"] = surfaceID }
        if let leasePath { result["lease_path"] = leasePath }
        var environment: [String: String] = [:]
        if let homeDirectory { environment["HOME"] = homeDirectory }
        if let codexHome { environment["CODEX_HOME"] = codexHome }
        if let stateDirectory { environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDirectory }
        if !environment.isEmpty { result["environment"] = environment }
        return result
    }

    private static func optionalIdentity(_ value: String?, maximumBytes: Int) -> String? {
        guard let value else { return nil }
        return identity(value, maximumBytes: maximumBytes)
    }

    private static func identity(_ value: String, maximumBytes: Int) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumBytes,
              !normalized.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }
        return normalized
    }

    private static func optionalPath(_ value: String?) -> String? {
        guard let value else { return nil }
        return identity(value, maximumBytes: 4_096)
    }
}
