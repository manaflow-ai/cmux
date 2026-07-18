/// Renderer-worker process identity and negotiated semantic-scene support.
public struct RendererWorkerReady: Equatable, Sendable {
    /// Renderer-worker process identifier.
    public let processID: UInt32

    /// Effective user identifier of the renderer-worker process.
    public let effectiveUserID: UInt32

    /// Semantic-scene features this worker can consume.
    public let sceneCapabilities: RendererSceneCapabilities

    /// Creates a validated ready reply.
    ///
    /// - Parameters:
    ///   - processID: Nonzero renderer-worker process identifier.
    ///   - effectiveUserID: Effective user identifier of the worker process.
    ///   - sceneCapabilities: Supported semantic-scene features.
    /// - Throws: ``RendererControlError`` when the PID or capability mask is invalid.
    public init(
        processID: UInt32,
        effectiveUserID: UInt32,
        sceneCapabilities: RendererSceneCapabilities
    ) throws {
        guard processID != 0 else {
            throw RendererControlError.invalidProcessIdentity
        }
        try RendererControlValidation.validateCapabilities(sceneCapabilities)
        self.processID = processID
        self.effectiveUserID = effectiveUserID
        self.sceneCapabilities = sceneCapabilities
    }
}
