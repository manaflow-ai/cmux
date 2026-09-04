import Foundation

/// A realized sidebar label or table that accepts ticks from the one
/// container-owned elapsed clock.
@MainActor
protocol SidebarAgentElapsedClockTarget: AnyObject {
    func sidebarAgentElapsedClockDidTick(at now: Date)
}
