public import Observation

/// Observable projection of a Chromium session's navigation and lifecycle state.
///
/// Fed by whichever task consumes ``ChromiumSession/events`` (normally
/// ``ChromiumWebView``); UI reads it via Observation.
@MainActor
@Observable
public final class ChromiumBrowserModel {
    /// URL of the visible page, empty until the first navigation event.
    public private(set) var currentURL = ""
    /// Title of the visible page.
    public private(set) var pageTitle = ""
    /// Whether the page is loading.
    public private(set) var isLoading = false
    /// PID of the Content Shell host process once it is ready.
    public private(set) var hostProcessID: Int32?
    /// Latest compositor `CAContext` ID, `nil` until the first compositor handoff.
    public private(set) var compositorContextID: UInt32?
    /// `true` after the browser process disconnects; the session is dead.
    public private(set) var isDisconnected = false

    /// Creates an empty model.
    public init() {}

    /// Folds one session event into the model.
    public func apply(_ event: ChromiumSessionEvent) {
        switch event {
        case .ready(let hostPID, let contextID):
            hostProcessID = hostPID
            if contextID != 0 {
                compositorContextID = contextID
            }
        case .compositorChanged(let contextID):
            if contextID != 0 {
                compositorContextID = contextID
            }
        case .navigationChanged(let url, let title, let isLoading):
            currentURL = url
            pageTitle = title
            self.isLoading = isLoading
        case .surfaceTreeChanged, .log:
            break
        case .disconnected:
            isDisconnected = true
            isLoading = false
        }
    }
}
