public import Foundation

/// The app's answers to decisions a page cannot make alone: navigation
/// policy, permissions, JavaScript dialogs, new pages and download
/// destinations.
///
/// The browser panel conforms. Engines call these on the main actor and
/// wait for the answer before continuing the page operation.
///
/// The WebKit adapter does not route through this delegate yet: WebKit pages
/// keep the panel's existing `WKNavigationDelegate`/`WKUIDelegate`. New
/// engines route every decision here so both engines share one policy.
@MainActor
public protocol BrowserPageUIDelegate: AnyObject {
    /// Decides whether a navigation loads.
    /// - Parameters:
    ///   - page: The page navigating.
    ///   - action: The navigation.
    /// - Returns: Allow, cancel, or download.
    func page(_ page: any BrowserPage, decidePolicyFor action: BrowserPageNavigationAction) async -> BrowserPageNavigationDecision

    /// Answers a permission request.
    /// - Parameters:
    ///   - page: The requesting page.
    ///   - request: What the page asks for.
    /// - Returns: Grant, deny, or let the engine prompt.
    func page(_ page: any BrowserPage, requestPermission request: BrowserPagePermissionRequest) async -> BrowserPagePermissionDecision

    /// Shows a JavaScript dialog and returns the user's answer.
    /// - Parameters:
    ///   - page: The page that opened the dialog.
    ///   - dialog: The dialog.
    /// - Returns: The user's answer.
    func page(_ page: any BrowserPage, runJavaScriptDialog dialog: BrowserPageJavaScriptDialog) async -> BrowserPageJavaScriptDialogResponse

    /// Handles a request to open a new page.
    /// - Parameters:
    ///   - page: The opening page.
    ///   - request: What the page asked for.
    /// - Returns: Whether the app handled it, the engine should open a popup, or it is blocked.
    func page(_ page: any BrowserPage, openNewPage request: BrowserPageOpenRequest) -> BrowserPageOpenDisposition

    /// Chooses where a download is saved.
    /// - Parameters:
    ///   - page: The downloading page.
    ///   - download: The download, in ``BrowserPageDownload/State/pending``.
    /// - Returns: The destination file URL, or `nil` to cancel the download.
    func page(_ page: any BrowserPage, destinationForDownload download: BrowserPageDownload) async -> URL?
}
