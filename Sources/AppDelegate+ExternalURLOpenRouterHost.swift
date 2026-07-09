import CmuxAuthRuntime
import CmuxWindowing
import Foundation

/// `AppDelegate`'s conformance to the external-URL open seam.
///
/// `ExternalURLOpenRouter` (CmuxWindowing) owns the ordered deep-link open flow
/// for `application(_:open:)`; these witnesses perform the irreducible live work
/// that cannot leave the app target: handling the app's cmux-scheme external
/// routes, routing auth callbacks through the live `auth` graph, classifying the
/// opened URLs, latching the startup open-intent, and the three window/workspace
/// open effects. The DEBUG `AuthDebugLog` diagnostics and the
/// `AuthCallbackRouter` fallback stay app-side here.
extension AppDelegate: ExternalURLOpenRouterHost {
    func handleExternalRoutes(_ urls: [URL]) -> Bool {
        #if DEBUG
        AuthDebugLog().log("auth.openURLs.received count=\(urls.count) summaries=\(urls.map(\.externalOpenDebugSummary).joined(separator: "|"))")
        #endif
        if handleCmuxExternalURLs(from: urls) {
            #if DEBUG
            AuthDebugLog().log("auth.openURLs.handledByExternalRoutes count=\(urls.count)")
            #endif
            return true
        }
        return false
    }

    func handleAuthCallbacks(_ urls: [URL]) {
        // Before the auth graph is configured, fall back to a default router
        // (built-in cmux schemes) so dropped callbacks are still detected.
        let callbackRouter = auth?.callbackRouter ?? AuthCallbackRouter()
        let authCallbacks = urls.filter(callbackRouter.isAuthCallbackURL)
        #if DEBUG
        AuthDebugLog().log("auth.openURLs.authCallbacks count=\(authCallbacks.count)")
        #endif
        if let browserSignIn = auth?.browserSignIn {
            for url in authCallbacks {
                Task { @MainActor in
                    let signedIn = await browserSignIn.handleCallbackURL(url)
                    if !signedIn {
                        AuthDebugLog().log("auth.callback did not complete sign-in")
                    }
                }
            }
        } else if !authCallbacks.isEmpty {
            AuthDebugLog().log("auth.callback dropped: auth graph not configured yet")
        }
    }

    func classifiedFileURLs(from urls: [URL]) -> [URL] {
        externalOpenURLClassifier.fileURLs(from: urls)
    }

    func classifiedDirectories(from urls: [URL]) -> [String] {
        externalOpenURLClassifier.directories(
            from: urls.filter { externalOpenURLClassifier.isDirectory($0) }
        )
    }

    func openFilePreview(filePath: String, debugSource: String) {
        _ = openFilePreviewInPreferredMainWindow(
            filePath: filePath,
            debugSource: debugSource
        )
    }

    func openWorkspaceForExternalDirectory(_ directory: String, debugSource: String) {
        externalOpenIntentCoordinator.openWorkspace(
            forExternalDirectory: directory,
            debugSource: debugSource
        )
    }
}
