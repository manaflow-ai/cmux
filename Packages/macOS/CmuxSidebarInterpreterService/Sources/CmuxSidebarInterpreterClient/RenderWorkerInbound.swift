/// A host → render-worker message on the framed stdin channel.
///
/// The render worker (see `runSidebarRenderWorker()` in
/// `CmuxSidebarRemoteRender`) applies messages strictly in arrival order: a
/// scene update re-interprets and re-renders, a resize re-frames the offscreen
/// surface, and a pointer event is replayed into the worker's view tree.
public enum RenderWorkerInbound: Codable, Sendable, Equatable {
    /// Show this file against this data context (see ``RenderScene``).
    case scene(RenderScene)
    /// The host surface was resized or changed backing scale.
    case resize(RenderSurfaceGeometry)
    /// A pointer interaction on the host surface to replay.
    case pointer(RenderPointerEvent)
    /// The host received an explicit reload request (CLI `sidebar reload`);
    /// `nil`/empty names mean "all sidebars".
    case reloadSidebars([String]?)
}
