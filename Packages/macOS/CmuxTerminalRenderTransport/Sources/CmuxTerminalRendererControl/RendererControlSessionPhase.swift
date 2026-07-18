/// Internal lifecycle phase shared across both control directions.
enum RendererControlSessionPhase: Equatable, Sendable {
    case awaitingBootstrap
    case awaitingReady
    case active
    case terminal
    case failed
}
