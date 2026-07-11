import CmuxAndroidEmulator

extension AppDelegate {
    /// Opens Android device selection directly inside the current workspace.
    func showAndroidEmulators() {
        guard let workspace = tabManager?.selectedWorkspace else { return }
        _ = workspace.openAndroidEmulatorPickerPane(
            coordinator: androidEmulatorEnvironment.coordinator
        )
    }

    func openAndroidEmulatorPane(_ device: AndroidVirtualDevice) {
        guard let workspace = tabManager?.selectedWorkspace,
              case .loaded(let snapshot) = androidEmulatorEnvironment.coordinator.loadState else { return }
        _ = workspace.openAndroidEmulatorPane(
            device: device,
            sdkRootURL: snapshot.sdkRootURL,
            coordinator: androidEmulatorEnvironment.coordinator
        )
    }

    func openFirstRunningAndroidEmulatorPane() -> Bool {
        guard case .loaded(let snapshot) = androidEmulatorEnvironment.coordinator.loadState,
              let device = snapshot.devices.first(where: { $0.state.isRunning }) else {
            return false
        }
        openAndroidEmulatorPane(device)
        return true
    }
}
