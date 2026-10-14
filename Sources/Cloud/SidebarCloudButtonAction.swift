import Foundation

/// Reveals Cloud on every press, introducing it explicitly while activation is off.
@MainActor
struct SidebarCloudButtonAction {
    let isAvailable: () -> Bool
    let isEnabled: () -> Bool
    let revealMachines: () -> Void
    let presentIntroduction: () -> Void

    func perform() {
        guard isAvailable() else { return }
        revealMachines()
        if !isEnabled() {
            presentIntroduction()
        }
    }
}
