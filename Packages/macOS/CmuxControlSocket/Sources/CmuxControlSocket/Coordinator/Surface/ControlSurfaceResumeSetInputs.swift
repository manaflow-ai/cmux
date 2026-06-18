internal import Foundation

/// The pre-parsed inputs for `surface.resume.set`, lifted from the legacy
/// `v2SurfaceResumeSet` body's param parsing.
///
/// The coordinator parses these (the `source` already mapped through the legacy
/// `v2PublicSurfaceResumeSource` `process-detected` → `manual` rule, and
/// `autoResume` already gated to the `agent-hook` source); the app constructs the
/// app-typed `SurfaceResumeBindingSnapshot`, runs the approval flow, and stores it.
public struct ControlSurfaceResumeSetInputs: Sendable, Equatable {
    /// The binding's display name (trimmed non-empty), if any.
    public let name: String?
    /// The binding's kind (trimmed non-empty), if any.
    public let kind: String?
    /// The resume command (trimmed, guaranteed non-empty by the coordinator).
    public let command: String
    /// The working directory (trimmed non-empty), if any.
    public let cwd: String?
    /// The checkpoint identifier (trimmed non-empty), if any.
    public let checkpointID: String?
    /// The binding source (already mapped: `process-detected` → `manual`), if any.
    public let source: String?
    /// The environment overrides (the legacy `v2StringMap`, or `nil`).
    public let environment: [String: String]?
    /// Whether automatic resume is requested (already gated: `true` only for the
    /// `agent-hook` source with `auto_resume == true`).
    public let autoResume: Bool

    /// Creates resume-set inputs.
    ///
    /// - Parameters:
    ///   - name: The binding's display name.
    ///   - kind: The binding's kind.
    ///   - command: The resume command.
    ///   - cwd: The working directory.
    ///   - checkpointID: The checkpoint identifier.
    ///   - source: The (already-mapped) binding source.
    ///   - environment: The environment overrides.
    ///   - autoResume: Whether automatic resume is requested.
    public init(
        name: String?,
        kind: String?,
        command: String,
        cwd: String?,
        checkpointID: String?,
        source: String?,
        environment: [String: String]?,
        autoResume: Bool
    ) {
        self.name = name
        self.kind = kind
        self.command = command
        self.cwd = cwd
        self.checkpointID = checkpointID
        self.source = source
        self.environment = environment
        self.autoResume = autoResume
    }
}
