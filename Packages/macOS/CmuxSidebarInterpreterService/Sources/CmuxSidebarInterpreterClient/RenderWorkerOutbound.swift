import CmuxSwiftRender

/// A render-worker → host message on the framed stdout channel.
///
/// The only data that ever crosses back into the host is the CoreAnimation
/// remote context id (a plain integer the window server resolves) and
/// ``ButtonAction`` command values — host-side cmux commands by design. No
/// view structure derived from the untrusted sidebar file reaches the host.
public enum RenderWorkerOutbound: Codable, Sendable, Equatable {
    /// The worker (re)created its remote CoreAnimation context; the host
    /// should display `CALayerHost` with this context id.
    case context(UInt32)
    /// The scene with this ``RenderScene/seq`` was applied and committed;
    /// answers the client's hang watchdog.
    case ack(UInt64)
    /// A button in the worker-rendered view fired; the host dispatches its
    /// commands on the real command surface.
    case action(ButtonAction)
}
