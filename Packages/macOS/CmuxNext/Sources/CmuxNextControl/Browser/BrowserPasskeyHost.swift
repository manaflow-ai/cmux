/// What ``BrowserPasskeyRequests`` asks of the app: whether a tab is in front of
/// the person, bringing it there, and the banner that asks them
/// (plans/cmux-next/agent-browser-passkey-DESIGN.md 3.2).
///
/// The app implements it with its panes, windows and `DesktopNotifier`, so every
/// requirement runs on the main actor; tests pass a recorder.
public protocol BrowserPasskeyHost: Sendable {
    /// Whether tab `tabID` is shown in its pane, in the key window, with the app
    /// active: the state in which WebKit and Chromium start a WebAuthn ceremony.
    @MainActor
    func isInFront(tabID: String) async -> Bool

    /// Brings tab `tabID` in front of the person: selects it in its pane, shows
    /// its workspace, raises its window and makes the page first responder.
    ///
    /// Called only after the person clicked the request, so it may change focus.
    /// - Throws: when the tab no longer exists.
    @MainActor
    func reveal(tabID: String) async throws

    /// Shows `request` to the person (a banner whose click answers it).
    @MainActor
    func post(_ request: BrowserPasskeyRequest) async

    /// Removes the banner of request `id` (answered, replaced or expired).
    @MainActor
    func withdraw(_ id: String) async
}
