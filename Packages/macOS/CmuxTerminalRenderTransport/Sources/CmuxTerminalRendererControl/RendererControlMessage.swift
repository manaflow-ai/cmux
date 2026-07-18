/// A typed renderer-control command or reply.
public enum RendererControlMessage: Equatable, Sendable {
    /// Establishes immutable daemon, workspace, and worker-lifetime identity.
    case bootstrap(RendererBootstrap)
    /// Attaches or replaces one terminal presentation.
    case upsertPresentation(RendererPresentationAttachment)
    /// Detaches one exact presentation lifetime.
    case removePresentation(RendererPresentationRemoval)
    /// Delivers bounded opaque Ghostty semantic scene bytes.
    case semanticScene(RendererSemanticScene)
    /// Releases one exact IOSurface pool slot after the host blit.
    case frameRelease(RendererControlFrameRelease)
    /// Ends the worker session cleanly.
    case shutdown
    /// Confirms worker process identity and scene capabilities.
    case ready(RendererWorkerReady)
    /// Requests a full semantic scene for one attached presentation.
    case needsFullScene(RendererNeedsFullScene)
    /// Ends the worker session after a bounded fatal diagnostic.
    case fatal(RendererFatal)
    /// Publishes exact worker-owned grid geometry for an applied scene.
    case presentationReady(RendererPresentationReady)
    /// Confirms an exact presentation can no longer publish frames.
    case presentationRemoved(RendererPresentationRemoved)

    /// The only permitted wire direction for this message type.
    public var direction: RendererControlDirection {
        switch self {
        case .bootstrap, .upsertPresentation, .removePresentation,
             .semanticScene, .frameRelease, .shutdown:
            .daemonToWorker
        case .ready, .needsFullScene, .fatal, .presentationReady, .presentationRemoved:
            .workerToDaemon
        }
    }
}
