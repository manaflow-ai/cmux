import CmuxNextBrowser
package import CmuxNextCloud
import CmuxNextPages
package import CmuxNextPopups
import Foundation

/// Connect GitHub's pages (the App's install page, its account chooser, an installation's settings, GitHub's authorize
/// page) open in the app's own sign-in panel over the window the person clicked in, not a browser tab or another app.
/// GitHub's return to the App's Setup URL (the console's `/integrations/callback`) is stopped before it loads, and the
/// app finishes the connect itself with its own sign-in: the only page left is GitHub's own. Leo, 2026-11-25: "it also
/// said "this app wants to reopen in" but you're already in the app. so it shouldnt say shit" and "like cant we own
/// more of this end of the flow?" The rules are ``CloudGitHubCompletion``'s (`opensInApp`, `endsInApp`, `nextInApp`).
@MainActor
package struct GitHubInstallSheet {
    package init() {}
    /// The app's sign-in panel at launch: other apps' sign-ins (installed as the system's session handler when the build
    /// serves them) and the app's own Connect GitHub (every ``LinkRouter/openGitHubConnect(_:)`` link, and GitHub's return
    /// in a WebKit tab, ``BrowserExternalApps/ownReturn``). Returns the handler, which the app keeps.
    package static func install(opener: any WebAuthSessionOpening, auth: CloudAuth) -> WebAuthSessionHandler {
        let broker = WebAuthSessionBroker(opener: opener)
        LinkRouter.shared.openGitHubInstall = { open($0, broker: broker, auth: auth) }
        BrowserExternalApps.shared.ownReturn = { CloudGitHubCompletion.ownReturn($0, auth: auth) }
        // A save on GitHub's installation settings in a cmux tab: read GitHub again, and no console page (#57470).
        BrowserExternalApps.shared.savedReturn = { url in
            guard CloudGitHubCompletion.isSavedOnGitHub(url) else { return false }
            auth.gitHubChanges.savedOnGitHub()
            return true
        }
        let handler = WebAuthSessionHandler(broker: broker)
        WebAuthSessionHandler.install(handler)
        return handler
    }

    /// Opens `url` in the panel when it is a github.com page; false for anything else (the caller opens it as before).
    static func open(_ url: URL, broker: WebAuthSessionBroker, auth: CloudAuth) -> Bool {
        guard CloudGitHubCompletion.opensInApp(url) else { return false }
        let scheme = auth.configuration.callbackScheme, api = auth.configuration.ownerAPIBaseURL()
        let console = CloudGitHubCompletion.consoleHost(production: auth.configuration.isProductionAuth)
        broker.begin(InAppWebAuthRequest(
            url: url, callback: .https(host: console, path: CloudGitHubCompletion.consoleCallbackPath),
            matches: { CloudGitHubCompletion.endsInApp($0, scheme: scheme, api: api) },
            redirect: { CloudGitHubCompletion.nextInApp($0, scheme: scheme, api: api) },
            complete: { CloudGitHubCompletion.finishInApp($0, auth: auth) },
            cancel: { auth.gitHubChanges.closedGitHub() }
        ))
        auth.gitHubChanges.openedGitHub()
        return true
    }
}
