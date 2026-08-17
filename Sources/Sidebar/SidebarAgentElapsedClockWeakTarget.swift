/// Weak registry entry for one realized elapsed-label target.
@MainActor
struct SidebarAgentElapsedClockWeakTarget {
    weak var value: (any SidebarAgentElapsedClockTarget)?
}
