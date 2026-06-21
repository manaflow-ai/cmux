/// The surface-resume-binding fields the session autosave fingerprint folds into
/// its hash, flattened off the app-target `SurfaceResumeBindingSnapshot`.
///
/// Carries only the values the legacy
/// `TabManager.hashSurfaceResumeBindingSnapshot(_:into:)` combined, in order:
/// name, kind, command, cwd, checkpointId, source, environment, the computed
/// `allowsAutomaticResume`, and then `updatedAt` only when the binding is not
/// process-detected (the legacy branch that excludes a live-process timestamp
/// from the fingerprint). The app-side ``SessionFingerprintHosting`` witness
/// reads the live snapshot's computed `allowsAutomaticResume`/`isProcessDetected`
/// and maps it into this value.
public struct SessionFingerprintSurfaceResumeBindingSnapshot: Sendable, Equatable {
    /// Legacy `SurfaceResumeBindingSnapshot.name`.
    public let name: String?
    /// Legacy `SurfaceResumeBindingSnapshot.kind`.
    public let kind: String?
    /// Legacy `SurfaceResumeBindingSnapshot.command`.
    public let command: String
    /// Legacy `SurfaceResumeBindingSnapshot.cwd`.
    public let cwd: String?
    /// Legacy `SurfaceResumeBindingSnapshot.checkpointId`.
    public let checkpointId: String?
    /// Legacy `SurfaceResumeBindingSnapshot.source`.
    public let source: String?
    /// Legacy `SurfaceResumeBindingSnapshot.environment`, hashed sorted by key.
    public let environment: [String: String]?
    /// Legacy computed `SurfaceResumeBindingSnapshot.allowsAutomaticResume`.
    public let allowsAutomaticResume: Bool
    /// Legacy computed `SurfaceResumeBindingSnapshot.isProcessDetected`; when
    /// true the fingerprint folds in `false` instead of ``updatedAt``.
    public let isProcessDetected: Bool
    /// Legacy `SurfaceResumeBindingSnapshot.updatedAt`, folded in only when
    /// ``isProcessDetected`` is false.
    public let updatedAt: Double?

    /// Creates a flattened surface-resume-binding fingerprint input.
    public init(
        name: String?,
        kind: String?,
        command: String,
        cwd: String?,
        checkpointId: String?,
        source: String?,
        environment: [String: String]?,
        allowsAutomaticResume: Bool,
        isProcessDetected: Bool,
        updatedAt: Double?
    ) {
        self.name = name
        self.kind = kind
        self.command = command
        self.cwd = cwd
        self.checkpointId = checkpointId
        self.source = source
        self.environment = environment
        self.allowsAutomaticResume = allowsAutomaticResume
        self.isProcessDetected = isProcessDetected
        self.updatedAt = updatedAt
    }
}
