extension CmuxSettingsFileStore {
    /// Creates the process store wired to the host's shared reload coordinator.
    static var appLive: CmuxSettingsFileStore {
        CmuxSettingsFileStore(
            onWatchedFileReload: { source in
                AppDelegate.shared?.reloadCmuxConfigStores(source: source)
            }
        )
    }
}
