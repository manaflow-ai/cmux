/// Signals that a recovery pass stopped before consuming its full page.
enum WorkstreamReadDeadline: Error {
    case exceeded
}
