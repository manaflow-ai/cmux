package import CmuxNextCompat

/// One window's parked workspaces, as ``ParkedWorkspaceRelease`` sees them (the App's
/// `WindowController`, a fake in tests).
@MainActor
package protocol ParkedWorkspaceHost: AnyObject {
    /// Whether the window is on screen: shown, not minimized and not fully covered.
    var showsOnScreen: Bool { get }
    /// The least recently shown parked workspace that may be torn down now, with its park serial; nil
    /// when none may (the window's own workspace under a top page, the ones `sidebar.multiView` shows).
    var oldestReleasableParked: (id: String, serial: UInt64)? { get }
    /// Tears down parked workspace `id`; it mounts again when shown.
    func releaseParked(_ id: String)
}

/// The parked workspaces of every window, as one lossy consumer of the app's memory coordinator
/// (p07-memory.md task 096).
///
/// Parked workspaces have no budget below critical pressure (task 032 adds one), so the coordinator's
/// policy gives this consumer 100 % until critical and 0 % there, as Chrome's urgent page discarding
/// policy (`chrome/browser/performance_manager/policies/urgent_page_discarding_policy.cc`). Each
/// release slice tears down one workspace and returns ``MemoryReleaseProgress/more``, so a slice never
/// holds two teardowns and 150 parked workspaces leave over 150 frames instead of in one main turn.
/// Hidden goes first: workspaces of windows off screen before those of windows on screen, each window's
/// least recently shown first, so the workspace a switch most likely returns to goes last. Every slice
/// reads the windows anew, so a workspace shown meanwhile is no longer parked and stays.
@MainActor
package final class ParkedWorkspaceRelease: MemoryConsumer {
    package static let memoryConsumerName = "parked-workspaces"
    /// Lossy: a remount resets the view-only state (strip and screen bar scroll).
    package static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .none, retention: .lossy, recreateCost: .expensive,
        releaseCPUCost: .high, isStateful: true, supportsMemoryLimit: false)

    /// How many parked workspaces it tore down (tests).
    package private(set) var teardowns = 0
    private let hosts: () -> [any ParkedWorkspaceHost]
    private var registration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - hosts: The app's windows now.
    ///   - registry: The app's memory coordinator.
    package init(hosts: @escaping () -> [any ParkedWorkspaceHost], registry: any MemoryConsumerRegistry) {
        self.hosts = hosts
        registration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    /// Nothing to lower: parking does not grow under a limit, only critical pressure releases.
    package func updateMemoryLimit(_ limit: MemoryLimit) {}

    /// At the critical limit, tears down one parked workspace per slice.
    package func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        guard slice.limit.isCritical, let next = nextRelease() else { return .done }
        next.host.releaseParked(next.id)
        teardowns += 1
        return .more
    }

    /// Unknown: a parked workspace's views have no byte count of their own.
    package var memoryUsage: MemoryUsage? { nil }

    /// The releasable parked workspace that goes first: off-screen windows before on-screen ones, then
    /// the least recently shown. O(parked workspaces), with no allocation per workspace.
    private func nextRelease() -> (host: any ParkedWorkspaceHost, id: String)? {
        var best: (host: any ParkedWorkspaceHost, id: String, onScreen: Bool, serial: UInt64)?
        for host in hosts() {
            guard let candidate = host.oldestReleasableParked else { continue }
            let onScreen = host.showsOnScreen
            if let current = best, (current.onScreen ? 1 : 0, current.serial) <= (onScreen ? 1 : 0, candidate.serial) { continue }
            best = (host, candidate.id, onScreen, candidate.serial)
        }
        return best.map { (host: $0.host, id: $0.id) }
    }
}
