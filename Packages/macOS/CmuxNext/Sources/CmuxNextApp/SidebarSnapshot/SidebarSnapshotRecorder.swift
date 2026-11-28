import CmuxNextSidebar

/// Saves one window's sidebar to `SidebarSnapshotStore` (SidebarBridge):
/// only what changed since the last save, in order.
struct SidebarSnapshotRecorder {
    /// What was last saved for this window, and the order of saves.
    private var lastRecorded: SidebarSnapshot?
    private var recordSequence: UInt64 = 0
    /// Once incognito, never saved, even after the window leaves the
    /// incognito set on its way out.
    private var everIncognito = false

    /// Saves what `model` shows (placeholders and live-only detail left
    /// out) once the launch is over, only for an open registered window
    /// and never an incognito one (a closing incognito window leaves the
    /// incognito set before its sidebar goes away).
    mutating func record(_ model: SidebarModel, window: String, services: AppServices) {
        let registry = services.windows.registry
        if registry.value.isIncognito(window) { everIncognito = true }
        guard !everIncognito, !registry.isLaunching, registry.value.window(window)?.isOpen == true else { return }
        let snapshot = SidebarSnapshot(sections: model.sections, profiles: model.profiles, activeProfileID: model.activeProfileID)
        guard snapshot != lastRecorded else { return }
        lastRecorded = snapshot
        recordSequence += 1
        let store = services.sidebarSnapshots, sequence = recordSequence
        Task { await store.record(snapshot, window: window, sequence: sequence) }
    }
}
