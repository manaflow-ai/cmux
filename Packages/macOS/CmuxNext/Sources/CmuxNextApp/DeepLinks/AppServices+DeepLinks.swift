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
    func link(workspace: WorkspaceModel) throws -> String {
        ""
    }

    /// Copy Pane Link's text: the pane's `pane_` resource id.
    func link(pane: PaneModel) throws -> String {
        ""
    }

    /// Copy Tab Link's text: the tab's `tab_` resource id.
    func link(tab: TabModel) throws -> String {
        ""
    }
}
