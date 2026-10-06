import class CmuxNextDesign.LaunchReveal

extension AgentTabStore {
    /// Whether `key`'s view in `pane` waits for the launch's first pane
    /// content. Not yet: every agent tab makes its view at once.
    func deferAtLaunch(_ key: String, reveal: LaunchReveal, focusedPane: String?, pane: String,
                       show: @escaping @MainActor () -> Void) -> Bool {
        false
    }
}
