/// Window geometry, application deactivation, or loss of the tracked window.
enum ExternalApplicationWindowEvent: Equatable, Sendable {
    case visible(ExternalApplicationWindowSnapshot)
    case hidden
    case offscreen
    case unavailable
}
