import CmuxSwiftRender

/// An asynchronous notification surfaced by ``RenderWorkerClient/subscribe()``.
///
/// `ack` frames are consumed internally by the client's hang watchdog; only
/// the events the host must react to are surfaced.
public enum RenderWorkerEvent: Sendable, Equatable {
    /// A (re)spawned worker announced its remote CoreAnimation context. The
    /// host swaps its `CALayerHost` to this id — this is also how the sidebar
    /// reappears after a worker crash.
    case context(UInt32)
    /// A button in the worker-rendered sidebar fired.
    case action(ButtonAction)
}
