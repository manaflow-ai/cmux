public import Foundation

/// A cmux action a page context menu offers in addition to the engine's own items.
///
/// These are the rows Classic adds to WebKit's menu; a Chromium page shows the same rows so the
/// menu does not depend on the engine.
public enum BrowserContextMenuHostAction: Hashable, Sendable {
    /// Opens the link in the user's default browser.
    case openLinkInDefaultBrowser(URL)
    /// Copies a screenshot of the whole page.
    case screenshotPage
    /// Starts a screenshot of a page section.
    case screenshotSection
    /// Moves the browser tab into a new workspace.
    case moveTabToNewWorkspace
    /// Enters or exits Browser Focus Mode; `isActive` is the current state.
    case toggleFocusMode(isActive: Bool)
}
