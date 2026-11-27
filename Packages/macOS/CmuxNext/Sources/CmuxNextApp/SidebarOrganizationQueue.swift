import CmuxNextSidebar

/// Sidebar organization intents (group create, move, rename, collapse,
/// order) sent before the home session's personal state is loaded. Groups
/// are personal rows of the local daemon, which loads them with its first
/// snapshot; an intent sent earlier waits for that snapshot instead of being
/// refused, and runs then (SidebarBridge.show drains it).
@MainActor
final class SidebarOrganizationQueue {
    /// At most this many intents wait; later ones are refused.
    static let limit = 32
    private(set) var intents: [SidebarIntent] = []

    /// Holds `intent` while `local` may still bring personal state. False
    /// when the caller must refuse it instead.
    func hold(_ intent: SidebarIntent, local: DaemonService) -> Bool {
        guard local.personalStateMayLoad, intents.count < Self.limit else { return false }
        intents.append(intent)
        return true
    }

    /// Runs the waiting intents once personal state is `loaded`; refuses
    /// them once it can no longer load (the daemon is unavailable or
    /// answered without `profiles-v1`); else keeps waiting.
    func drain(loaded: Bool, local: DaemonService, run: (SidebarIntent) -> Void, refuse: () -> Void) {
        guard !intents.isEmpty, loaded || !local.personalStateMayLoad else { return }
        let pending = intents
        intents = []
        if loaded { pending.forEach(run) } else { refuse() }
    }
}
