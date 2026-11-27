public import Foundation

/// How a pane that was discarded for memory brings its page back when it is
/// shown again.
///
/// WebKit's `interactionState` carries the native back/forward list together
/// with each entry's scroll and view state, so assigning it to the replacement
/// web view returns the page the user left, like a Chrome tab discard. Loading
/// the URL from scratch is the fallback for panes whose captured state cannot
/// be replayed safely.
public enum BrowserDiscardRestoreStrategy: Equatable, Sendable {
    /// Assign the captured WebKit session state to the replacement web view.
    case restoreInteractionState(Data)
    /// Load the restore URL from scratch.
    case replayURL(URL)

    /// Pane conditions that force the URL fallback.
    public struct Conditions: Equatable, Sendable {
        /// The user asked for a reload, which must fetch a fresh document.
        public var isExplicitReload: Bool
        /// A remote workspace pane. Its pages load through a loopback proxy
        /// whose endpoint can change across reconnects, so session state would
        /// replay stale proxy URLs. The URL path also queues until the
        /// endpoint is up.
        public var usesRemoteWorkspaceProxy: Bool
        /// Cloud browser routing owns its own connection flow.
        public var usesCloudAccessRouting: Bool
        /// The web content process died and recovery replaces the web view.
        public var hasRecoverableWebContentTermination: Bool
        /// An http page the insecure-HTTP gate would stop. Session state
        /// replays as a back/forward load, which asks again; the URL path
        /// reopens a page the user already chose to open without asking.
        public var requiresInsecureHTTPConsent: Bool

        public init(
            isExplicitReload: Bool = false,
            usesRemoteWorkspaceProxy: Bool = false,
            usesCloudAccessRouting: Bool = false,
            hasRecoverableWebContentTermination: Bool = false,
            requiresInsecureHTTPConsent: Bool = false
        ) {
            self.isExplicitReload = isExplicitReload
            self.usesRemoteWorkspaceProxy = usesRemoteWorkspaceProxy
            self.usesCloudAccessRouting = usesCloudAccessRouting
            self.hasRecoverableWebContentTermination = hasRecoverableWebContentTermination
            self.requiresInsecureHTTPConsent = requiresInsecureHTTPConsent
        }

        var forcesURLReplay: Bool {
            isExplicitReload
                || usesRemoteWorkspaceProxy
                || usesCloudAccessRouting
                || hasRecoverableWebContentTermination
                || requiresInsecureHTTPConsent
        }
    }

    /// Whether session state may be captured, persisted or restored for a
    /// document at `url`. Web and local file documents qualify; the caller
    /// re-grants a local file's trust before assigning the state. App-internal
    /// documents such as the diff viewer resolve through their own handlers,
    /// which a back/forward replay would bypass.
    public static func canRestoreSessionState(for url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    /// Picks the restore path for `restoreURL`. Captured state is used only
    /// when it was taken for the same page the pane is about to restore, so a
    /// navigation issued while the pane was discarded always wins. A page
    /// shown as a form submission result loads by URL, because assigning its
    /// state would send the form again.
    public static func resolve(
        restoreURL: URL,
        capture: BrowserPageStateCapture?,
        conditions: Conditions = Conditions()
    ) -> BrowserDiscardRestoreStrategy {
        guard !conditions.forcesURLReplay,
              canRestoreSessionState(for: restoreURL),
              let capture,
              capture.anchorURL == restoreURL,
              !capture.documentHasFormSubmission,
              let interactionState = capture.interactionState,
              !interactionState.isEmpty else {
            return .replayURL(restoreURL)
        }
        return .restoreInteractionState(interactionState)
    }
}
