import Foundation
import Observation

/// Main-actor registry driven by one TimelineView for the whole sidebar.
/// Targets are weak and limited to realized elapsed labels plus the AppKit
/// table controller; a tick never scans the sidebar's full row collection.
@MainActor
@Observable
final class SidebarAgentElapsedClock {
    // Registration happens from realized-row AppKit callbacks. Keep this
    // demand bit ignored so those callbacks never invalidate the lazy parent.
    @ObservationIgnored
    private var targets: [ObjectIdentifier: SidebarAgentElapsedClockWeakTarget] = [:]
    @ObservationIgnored
    private let displayCache = SidebarAgentActivityDisplayCache()

    var actions: SidebarAgentElapsedClockActions {
        let cache = displayCache
        return SidebarAgentElapsedClockActions(
            identity: ObjectIdentifier(self),
            register: { [weak self] target in self?.register(target) },
            unregister: { [weak self] target in self?.unregister(target) },
            displayPayload: { activity, now in
                cache.payload(for: activity, at: now)
            }
        )
    }

    private func register(_ target: any SidebarAgentElapsedClockTarget) {
        targets[ObjectIdentifier(target)] = SidebarAgentElapsedClockWeakTarget(value: target)
    }

    private func unregister(_ target: any SidebarAgentElapsedClockTarget) {
        targets.removeValue(forKey: ObjectIdentifier(target))
    }

    func tick(at now: Date) {
        var releasedTargets: [ObjectIdentifier] = []
        for (identifier, target) in targets {
            guard let value = target.value else {
                releasedTargets.append(identifier)
                continue
            }
            value.sidebarAgentElapsedClockDidTick(at: now)
        }
        for identifier in releasedTargets {
            targets.removeValue(forKey: identifier)
        }
    }
}
