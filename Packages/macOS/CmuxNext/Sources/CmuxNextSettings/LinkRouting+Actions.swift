public import CmuxNextActions

extension LinkRouting {
    /// The palette's Links: Open in cmux Browser (`links.openInCmuxBrowser`) and Links: Open in
    /// Default Browser (`links.openInDefaultBrowser`): each writes `browser.openLinksInCmuxBrowser`
    /// true or false, written out even for the default so classic's key cannot apply under it, and
    /// refused while the key is managed. The settings reload applies it. Sign-In Pages: Open in cmux
    /// Browser and Sign-In Pages: Follow Link Settings write `browser.openSignInPagesInCmux` the same way.
    @MainActor public static func bindActions(into registry: ActionRegistry, save: @escaping SettingChoiceActions.Save) {
        SettingChoiceActions.bind([true, false], into: registry, id: { $0 ? "links.openInCmuxBrowser" : "links.openInDefaultBrowser" },
                                  path: openPath, fileValue: { .bool($0) }, save: save) { _ in }
        // Sign-In Pages: in cmux Browser (`links.signInPagesInCmux`) or by the link settings
        // (`links.signInPagesByLinkSettings`): `browser.openSignInPagesInCmux` true or false.
        SettingChoiceActions.bind([true, false], into: registry, id: { $0 ? "links.signInPagesInCmux" : "links.signInPagesByLinkSettings" },
                                  path: signInPagesPath, fileValue: { .bool($0) }, save: save) { _ in }
    }
}
