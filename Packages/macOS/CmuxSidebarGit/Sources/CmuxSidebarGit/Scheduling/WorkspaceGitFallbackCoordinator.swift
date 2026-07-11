public import Foundation
internal import CmuxGit

/// One process-wide five-minute fallback clock for every sidebar git service.
///
/// The composition root injects one coordinator into all windows. A tick
/// allocates one round token and synchronously broadcasts it to every active
/// service, so panels queued behind the shared probe limiter retain the same
/// authority. Weak registrations do not extend a window's lifetime.
@MainActor
public final class WorkspaceGitFallbackCoordinator {
    private struct WeakService {
        weak var value: SidebarGitMetadataService?
    }

    private let clock: any GitPollClock
    private let interval: TimeInterval
    private var namespace = UUID()
    private var generation: UInt64 = 0
    private var services: [UUID: WeakService] = [:]
    private var fallbackTask: Task<Void, Never>?

    /// Creates an injectable coordinator with one clock and timer.
    public init(
        clock: any GitPollClock = SystemGitPollClock(),
        interval: TimeInterval = 5 * 60
    ) {
        self.clock = clock
        self.interval = max(0, interval)
    }

    func register(_ service: SidebarGitMetadataService, registrationID: UUID) {
        services[registrationID] = WeakService(value: service)
        serviceStateDidChange()
    }

    func unregister(_ registrationID: UUID) {
        services.removeValue(forKey: registrationID)
        serviceStateDidChange()
    }

    func serviceStateDidChange() {
        pruneReleasedServices()
        let hasActiveService = services.values.contains {
            $0.value?.requiresWorkspaceGitFallback == true
        }
        if hasActiveService {
            startTimerIfNeeded()
        } else {
            fallbackTask?.cancel()
            fallbackTask = nil
        }
    }

    func fireFallbackRound() {
        broadcastFallbackRound()
    }

    private func startTimerIfNeeded() {
        guard fallbackTask == nil else { return }
        let clock = clock
        let interval = interval
        fallbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.broadcastFallbackRound()
                self.pruneReleasedServices()
                guard self.services.values.contains(where: {
                    $0.value?.requiresWorkspaceGitFallback == true
                }) else {
                    self.fallbackTask = nil
                    return
                }
            }
        }
    }

    private func broadcastFallbackRound() {
        pruneReleasedServices()
        if generation == .max {
            namespace = UUID()
            generation = 0
        } else {
            generation += 1
        }
        let round = GitFallbackRoundID(
            namespace: namespace,
            sequence: generation
        )
        let activeServices = services.values.compactMap(\.value).filter {
            $0.requiresWorkspaceGitFallback
        }
        for service in activeServices {
            service.receiveWorkspaceGitFallbackRound(round)
        }
    }

    private func pruneReleasedServices() {
        services = services.filter { $0.value.value != nil }
    }
}
