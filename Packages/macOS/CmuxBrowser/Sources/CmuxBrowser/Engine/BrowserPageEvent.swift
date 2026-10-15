public import Foundation

/// Something that happened in a page, delivered through ``BrowserPage/events``.
public enum BrowserPageEvent: Equatable, Sendable {
    /// Any field of the page state changed; the value is the new state.
    case stateChanged(BrowserPageState)
    /// The page favicon changed; PNG data, or `nil` when the page has none.
    case faviconChanged(Data?)
    /// A main-frame navigation started.
    case navigationStarted(URL?)
    /// A main-frame navigation committed its first bytes.
    case navigationCommitted(URL?)
    /// A main-frame navigation finished loading.
    case navigationFinished(URL?)
    /// A main-frame navigation failed. `showsEngineErrorPage` is `true` when
    /// the engine drew its own error or interstitial page (Chromium's
    /// certificate and network error pages), so the app shows no error view
    /// of its own over it.
    case navigationFailed(URL?, code: Int, message: String, showsEngineErrorPage: Bool)
    /// The page's content process ended.
    case processTerminated(BrowserPageProcessExit)
    /// The page stopped (`true`) or resumed (`false`) handling input. While
    /// unresponsive, the app may offer to wait or end the page with
    /// ``BrowserPage/answerUnresponsive(terminate:)``.
    case unresponsiveChanged(Bool)
    /// A download started or progressed.
    case downloadUpdated(BrowserPageDownload)
    /// The pointer moved over a link, or off links (`nil`).
    case linkHovered(URL?)
    /// The page wrote to its console.
    case consoleMessage(level: String, text: String)
    /// Page content entered or left fullscreen.
    case contentFullscreenChanged(Bool)
    /// Developer tools opened or closed.
    case devToolsVisibilityChanged(Bool)
    /// The page asked to close itself (`window.close()`).
    case closeRequested
}
