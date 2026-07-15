/// One ordered input to a view-scoped title coalescer.
enum GhosttyTitleUpdateEvent: Sendable {
    case update(GhosttyTitleUpdate)
    case retire(GhosttyTitleUpdateSurfaceKey)
}
