import Foundation
import Observation

/// Refreshable process catalog used by command-palette and context-menu forks.
/// Filesystem discovery runs away from the main actor.
@MainActor
@Observable
final class AgentConversationForkTargetCatalog {
    private(set) var installedTargets: [AgentConversationForkTarget]

    @ObservationIgnored
    private let minimumRefreshInterval: TimeInterval
    @ObservationIgnored
    private let customDiscovery: (@Sendable () -> [AgentConversationForkTarget])?
    @ObservationIgnored
    private var lastRefreshDate: Date?
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?

    convenience init() {
        self.init(
            initialTargets: [],
            minimumRefreshInterval: 2,
            customDiscovery: nil
        )
    }

    convenience init(
        initialTargets: [AgentConversationForkTarget] = [],
        minimumRefreshInterval: TimeInterval = 2,
        discovery: @escaping @Sendable () -> [AgentConversationForkTarget]
    ) {
        self.init(
            initialTargets: initialTargets,
            minimumRefreshInterval: minimumRefreshInterval,
            customDiscovery: discovery
        )
    }

    private init(
        initialTargets: [AgentConversationForkTarget],
        minimumRefreshInterval: TimeInterval,
        customDiscovery: (@Sendable () -> [AgentConversationForkTarget])?
    ) {
        installedTargets = initialTargets
        self.minimumRefreshInterval = minimumRefreshInterval
        self.customDiscovery = customDiscovery
    }

    func refreshIfNeeded(force: Bool = false) {
        guard refreshTask == nil else { return }
        if !force,
           let lastRefreshDate,
           Date().timeIntervalSince(lastRefreshDate) < minimumRefreshInterval {
            return
        }

        let discovery: @Sendable () -> [AgentConversationForkTarget]
        if let customDiscovery {
            discovery = customDiscovery
        } else {
            // Capture current settings for every pass so changing a configured
            // executable path takes effect without restarting cmux.
            let discoverer = AgentConversationForkTargetDiscoverer.live()
            discovery = { discoverer.discover() }
        }
        refreshTask = Task { [weak self] in
            let targets = await Task.detached(priority: .utility) {
                discovery()
            }.value
            guard !Task.isCancelled, let self else { return }
            if installedTargets != targets {
                installedTargets = targets
            }
            lastRefreshDate = Date()
            refreshTask = nil
        }
    }

    func refresh(force: Bool = false) async {
        refreshIfNeeded(force: force)
        let task = refreshTask
        await task?.value
    }
}
