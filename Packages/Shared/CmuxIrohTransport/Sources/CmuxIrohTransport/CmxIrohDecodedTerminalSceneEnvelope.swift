/// One decoded terminal-scene envelope and its exact wire length.
public struct CmxIrohDecodedTerminalSceneEnvelope: Equatable, Sendable {
    public let envelope: CmxIrohTerminalSceneEnvelope
    public let consumedByteCount: Int

    public init(
        envelope: CmxIrohTerminalSceneEnvelope,
        consumedByteCount: Int
    ) {
        self.envelope = envelope
        self.consumedByteCount = consumedByteCount
    }
}
