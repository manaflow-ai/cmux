import CmuxNextBridge
import CmuxNextSidebar
import Observation

/// The rows of other spaces for the sidebar's swipe pages (R99).
@MainActor final class SpaceSectionsCache {
    private(set) var computations = 0

    func sections(for key: SidebarProfileKey, compute: () -> [SidebarRowSection]) -> [SidebarRowSection] {
        computations += 1
        return compute()
    }
}
