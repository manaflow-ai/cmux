import Foundation
import SwiftUI

/// A realized sidebar label or table that accepts ticks from the one
/// container-owned elapsed clock.
@MainActor
protocol SidebarAgentElapsedClockTarget: AnyObject {
    func sidebarAgentElapsedClockDidTick(at now: Date)
}

/// Closure capability passed below the sidebar's lazy-list boundary.
///
/// The value is deliberately not observable: registering a realized label
/// cannot invalidate `VerticalTabsSidebar` or rebuild its row snapshots.
@MainActor
struct SidebarAgentElapsedClockActions {
    let identity: ObjectIdentifier
    let register: (any SidebarAgentElapsedClockTarget) -> Void
    let unregister: (any SidebarAgentElapsedClockTarget) -> Void
}

/// Main-actor registry driven by one TimelineView for the whole sidebar.
/// Targets are weak and limited to realized elapsed labels plus the AppKit
/// table controller; a tick never scans the sidebar's full row collection.
@MainActor
final class SidebarAgentElapsedClock {
    private struct WeakTarget {
        weak var value: (any SidebarAgentElapsedClockTarget)?
    }

    private var targets: [ObjectIdentifier: WeakTarget] = [:]

    var actions: SidebarAgentElapsedClockActions {
        SidebarAgentElapsedClockActions(
            identity: ObjectIdentifier(self),
            register: { [weak self] target in self?.register(target) },
            unregister: { [weak self] target in self?.unregister(target) }
        )
    }

    private func register(_ target: any SidebarAgentElapsedClockTarget) {
        targets[ObjectIdentifier(target)] = WeakTarget(value: target)
    }

    private func unregister(_ target: any SidebarAgentElapsedClockTarget) {
        targets.removeValue(forKey: ObjectIdentifier(target))
    }

    fileprivate func tick(at now: Date) {
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
