import CmuxNextApps
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSidebar

/// The window's custom sidebar (plans/cmux-next/custom-sidebar-DESIGN.md): mounted while the
/// user's own app implements `cmux.sidebar/1`, remounted when its script reloads or after a failed
/// render. With no script nothing mounts; the only cost is this observation of the app list.
extension SidebarBridge {
    func observeCustomSidebar() {
        let customization = services.sidebarCustomization
        // task-owner: one watch per window bridge, cancelled in teardown().
        customSidebarObservation = Task { [weak self] in
            // A trigger: the same key remounts after a failed render (a fixed script keeps its version).
            for await key in ObservationStream({ ObservationTrigger(customization.customSidebarKey) }) {
                self?.showCustomSidebar(key.value)
            }
        }
    }

    private func showCustomSidebar(_ key: String?) {
        let failed = customSidebarMount.map { $0.content.errorText != nil } ?? false
        guard key != customSidebarMount?.key || failed else { return }
        releaseCustomSidebar()
        guard let key, let content = services.sidebarCustomization.makeCustomSidebar() else { return }
        customSidebarMount = (key, content)
        container.sidebarView.customSidebar = content
    }

    func releaseCustomSidebar() {
        guard let mount = customSidebarMount else { return }
        customSidebarMount = nil
        container.sidebarView.customSidebar = nil
        mount.content.release()
    }
}
