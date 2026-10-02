import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

extension AppServices {
    /// This build's URL scheme, the one sign-in calls back on: `cmux` in
    /// Release, `cmux-dev` in Debug, `cmux-dev-<tag>` in tagged builds
    /// (`CloudConfiguration.callbackScheme`). Copy Link writes it and
    /// `link.open` opens only it.
    var linkScheme: String { cloud.configuration.callbackScheme }

    /// `link` as text in this build's scheme; nil when an id does not fit
    /// its kind.
    func linkText(_ link: DeepLink) -> String? {
        link.url(scheme: linkScheme)?.absoluteString
    }
}

extension AppServices {
    /// Copy Workspace Link's text: the workspace's `ws_` resource id.
    /// - Throws: `ActionFailure` when its daemon gives it none; a link is
    ///   never built from a numeric handle.
    func link(workspace: WorkspaceModel) throws -> String {
        try link(workspace.resourceID.map { DeepLink(.workspace($0.rawValue)) })
    }

    /// Copy Pane Link's text: the pane's `pane_` resource id.
    func link(pane: PaneModel) throws -> String {
        try link(pane.resourceID.map { DeepLink(.pane($0.rawValue)) })
    }

    /// Copy Tab Link's text: the tab's `tab_` resource id.
    func link(tab: TabModel) throws -> String {
        try link(tab.snapshot.tabResourceID.map { DeepLink(.tab($0.rawValue)) })
    }

    private func link(_ link: DeepLink?) throws -> String {
        guard let text = link.flatMap(linkText) else { throw ActionFailure(message: RefusalStrings.noLinkID) }
        return text
    }
}
