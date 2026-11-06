public import Foundation

/// What opening an app shows (`app.open`, the app's sidebar item, the palette's Open <App>, the
/// App Store's Open button).
///
/// One rule for every entry point: an app's own scene page (`cmux.pane/1` with a scene export)
/// wins; a remote pane (`cmux.pane/1` with `remote: instance`) opens its running instance's URL in
/// a browser tab, or has nothing to open yet while it is not deployed; else a web app
/// (`presentation.web`, https only) opens as a browser tab; else the app has nothing to open
/// (a command-only app).
///
/// ```swift
/// switch AppOpenTarget(record) {
/// case .scenePane: showPanePage(record)
/// case .web(let url): openBrowserTab(url)
/// case .notDeployed: throw AppsServiceError.notDeployed
/// case .none: throw AppsServiceError.noPage
/// }
/// ```
public nonisolated enum AppOpenTarget: Sendable, Hashable {
    /// The app's scene pane, rendered natively as a page tab.
    case scenePane
    /// This URL in a browser tab of the active workspace: a web app's https URL, or a remote
    /// pane's running instance.
    case web(URL)
    /// A remote pane whose instance is not running (not deployed, or still deploying).
    case notDeployed
    /// Nothing to open: the app has only commands, sections or status items.
    case none

    /// Resolves what opening an installed app shows, its instance included.
    /// - Parameter record: The supervisor's record of the app.
    public init(_ record: AppRecord) {
        if record.manifest.remotePane {
            if record.instance?.state == .running, let url = record.instance?.url {
                self = .web(url)
            } else {
                self = .notDeployed
            }
        } else {
            self.init(record.manifest)
        }
    }

    /// Resolves what opening the app described by `manifest` shows, without instance facts (a
    /// remote pane then counts as not deployed).
    /// - Parameter manifest: The app's manifest.
    public init(_ manifest: AppManifest) {
        if manifest.scenePane != nil {
            self = .scenePane
        } else if manifest.remotePane {
            self = .notDeployed
        } else if let url = manifest.presentation?.web?.url, url.scheme?.lowercased() == "https", url.host?.isEmpty == false {
            self = .web(url)
        } else {
            self = .none
        }
    }
}
