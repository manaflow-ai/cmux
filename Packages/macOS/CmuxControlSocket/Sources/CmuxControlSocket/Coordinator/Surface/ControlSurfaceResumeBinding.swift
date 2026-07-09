internal import Foundation

/// A read-only snapshot of a surface's resume binding, as the app target exposes
/// it to ``ControlCommandCoordinator`` for the `resume_binding` payload value.
///
/// Mirrors the legacy `v2SurfaceResumeBindingPayload` dictionary exactly (built
/// after `SurfaceResumeApprovalStore.applyingStoredApproval`). Every optional maps
/// to a legacy `v2OrNull` write. The app resolves all app-side approval state
/// (`SurfaceResumeApprovalStore`) before constructing this value; the coordinator
/// only shapes the payload.
public struct ControlSurfaceResumeBinding: Sendable, Equatable {
    /// The binding's display name, if any.
    public let name: String?
    /// The binding's kind, if any.
    public let kind: String?
    /// The resume command.
    public let command: String
    /// The working directory, if any.
    public let cwd: String?
    /// The checkpoint identifier, if any.
    public let checkpointID: String?
    /// The binding source, if any.
    public let source: String?
    /// The environment overrides, if any (the legacy payload wrote the whole map
    /// or `null`).
    public let environment: [String: String]?
    /// Whether the binding allows automatic resume
    /// (`effectiveBinding.allowsAutomaticResume`).
    public let autoResume: Bool
    /// The approval policy's raw value, if any.
    public let approvalPolicyRawValue: String?
    /// The approval record identifier, if any.
    public let approvalRecordID: String?
    /// The last-updated timestamp (seconds since the epoch).
    public let updatedAt: Double

    /// Creates a resume-binding snapshot.
    ///
    /// - Parameters:
    ///   - name: The binding's display name.
    ///   - kind: The binding's kind.
    ///   - command: The resume command.
    ///   - cwd: The working directory.
    ///   - checkpointID: The checkpoint identifier.
    ///   - source: The binding source.
    ///   - environment: The environment overrides.
    ///   - autoResume: Whether automatic resume is allowed.
    ///   - approvalPolicyRawValue: The approval policy's raw value.
    ///   - approvalRecordID: The approval record identifier.
    ///   - updatedAt: The last-updated timestamp.
    public init(
        name: String?,
        kind: String?,
        command: String,
        cwd: String?,
        checkpointID: String?,
        source: String?,
        environment: [String: String]?,
        autoResume: Bool,
        approvalPolicyRawValue: String?,
        approvalRecordID: String?,
        updatedAt: Double
    ) {
        self.name = name
        self.kind = kind
        self.command = command
        self.cwd = cwd
        self.checkpointID = checkpointID
        self.source = source
        self.environment = environment
        self.autoResume = autoResume
        self.approvalPolicyRawValue = approvalPolicyRawValue
        self.approvalRecordID = approvalRecordID
        self.updatedAt = updatedAt
    }
}
