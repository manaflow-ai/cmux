public import CmuxNextActions

extension LinkRouting {
    /// The palette's Links: Open in cmux Browser (`links.openInCmuxBrowser`) and Links: Open in
    /// Default Browser (`links.openInDefaultBrowser`): each writes `browser.openLinksInCmuxBrowser`
    /// true or false, written out even for the default so classic's key cannot apply under it, and
    /// refused while the key is managed. The settings reload applies it.
    @MainActor public static func bindActions(into registry: ActionRegistry, save: @escaping SettingChoiceActions.Save) {
        SettingChoiceActions.bind([true, false], into: registry, id: { $0 ? "links.openInCmuxBrowser" : "links.openInDefaultBrowser" },
                                  path: openPath, fileValue: { .bool($0) }, save: save) { _ in }
    }
}
