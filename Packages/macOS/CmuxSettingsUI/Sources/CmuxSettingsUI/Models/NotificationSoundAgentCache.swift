import Observation

/// The per-agent notification sound list, loaded once per Settings window.
///
/// The detail shows one pane at a time, so the App pane is rebuilt on every
/// visit. Loading the agent list from the pane made the matrix swap from
/// "No registered agents found." to the full grid after the pane appeared,
/// pushing every row below it down after a search hit had already scrolled
/// to it. The window owns this cache and starts the load when it opens, so
/// a revisit renders the final height immediately.
@MainActor
@Observable
public final class NotificationSoundAgentCache {
    /// `nil` until the first load finishes. An empty list is loaded again
    /// on the next request, so an agent registered while Settings is open
    /// still shows up.
    public private(set) var agents: [NotificationSoundAgentOption]?
    @ObservationIgnored private var isLoading = false

    public init() {}

    deinit {}

    /// Runs `load` unless a non-empty list is already loaded or a load is
    /// in flight.
    public func loadIfNeeded(_ load: @MainActor () async -> [NotificationSoundAgentOption]) async {
        guard agents?.isEmpty != false, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        agents = await load()
    }
}
