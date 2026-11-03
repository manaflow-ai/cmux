@testable import CmuxNextDesign
@testable import CmuxNextSidebar

extension SidebarChangeMotion {
    /// Sets the sidebar's change motion (`sidebar.changeMotion`) for one test, for a test of the motion before #34264
    /// (`wholeList`: rows a change shifts slide, closing rows close their slot, a fold clips, a reveal scrolls).
    /// Returns the reset.
    @MainActor static func use(_ motion: SidebarChangeMotion) -> () -> Void {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(tunable.key, .choice(motion.rawValue))
        return { _ = TunableStore.shared.set(tunable.key, nil) }
    }
}
