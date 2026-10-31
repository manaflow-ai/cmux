public import Foundation

/// What opening an app shows (`app.open`, the app's sidebar item, the App Store's Open button).
///
/// One rule for every entry point: an app's own scene page (`cmux.pane/1` with a scene export)
/// wins; else its web app (`presentation.web`, https only) opens as a browser tab in the active
/// workspace; else the app has nothing to open (a command-only app).
///
/// ```swift
/// switch AppOpenTarget(app.manifest) {
/// case .scenePane: showPanePage(app)
/// case .web(let url): openBrowserTab(url)
/// case .none: throw AppsServiceError.noPage
/// }
/// ```
public nonisolated enum AppOpenTarget: Sendable, Hashable {
    /// The app's scene pane, rendered natively as a page tab.
    case scenePane
    /// A web app: this https URL in a browser tab of the active workspace.
    case web(URL)
    /// Nothing to open: the app has only commands, sections or status items.
    case none

    /// Resolves what opening the app described by `manifest` shows.
    /// - Parameter manifest: The installed app's manifest.
    public init(_ manifest: AppManifest) {
        if manifest.scenePane != nil {
            self = .scenePane
        } else if let url = manifest.presentation?.web?.url, url.scheme?.lowercased() == "https", url.host?.isEmpty == false {
            self = .web(url)
        } else {
            self = .none
        }
    }
}
