/// Implemented by a page's UI delegate (the browser panel) for engines that
/// must know more than grant or deny: whether a grant is one-time (Chromium
/// saves every accepted prompt, so the engine resets a one-time grant right
/// after accepting it) and when the engine ended its own question.
///
/// An engine checks for it before falling back to
/// ``BrowserPageUIDelegate/page(_:requestPermission:)``.
@MainActor
public protocol BrowserPagePermissionOutcomeDelegate: AnyObject {
    /// Decides a permission request.
    /// - Returns: The decision, with ``BrowserPagePermissionDecision/prompt``
    ///   meaning no answer, and whether a grant is one-time.
    func page(_ page: any BrowserPage, decidePermission request: BrowserPagePermissionRequest) async -> BrowserPagePermissionCoordinator.Outcome

    /// The engine ended the page's pending permission question itself
    /// (navigation, page closed): its prompt goes away unanswered.
    func pageDidEndPermissionRequest(_ page: any BrowserPage)
}
