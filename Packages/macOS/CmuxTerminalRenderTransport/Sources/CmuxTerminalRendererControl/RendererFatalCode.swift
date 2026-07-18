/// A bounded machine-readable renderer-worker failure category.
public enum RendererFatalCode: UInt32, Sendable {
    /// The peer violated the renderer-control protocol.
    case protocolViolation = 1

    /// The worker could not decode semantic scene data.
    case sceneDecodeFailure = 2

    /// The worker could not initialize its render resources.
    case rendererInitializationFailure = 3

    /// The worker failed while drawing a scene.
    case renderFailure = 4

    /// The worker could not publish a completed frame.
    case frameTransportFailure = 5

    /// A bounded resource pool or allocation budget was exhausted.
    case resourceExhausted = 6

    /// A worker invariant failed without a narrower category.
    case internalInvariant = 7
}
