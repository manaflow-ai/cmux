/// The bounded pointer callbacks pending for one runtime lifetime.
struct GhosttyPointerStyleIngressRuntimePending: Sendable {
    var firstShape: GhosttyPointerStyleIngressRequest?
    var latestShape: GhosttyPointerStyleIngressRequest?
    var latestLinkHover: GhosttyPointerStyleIngressRequest?
    var latestRuntimeReset: GhosttyPointerStyleIngressRequest?
    var latestRuntimeEnded: GhosttyPointerStyleIngressRequest?
}
