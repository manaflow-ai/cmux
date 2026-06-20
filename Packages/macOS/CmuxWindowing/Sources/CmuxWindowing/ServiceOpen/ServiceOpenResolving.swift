public import AppKit

/// Resolves the candidate file-system paths carried by a Finder NSServices
/// `openWindow`/`openTab` pasteboard into a list of URLs the app should act
/// on.
///
/// This is the seam for the pasteboard path resolution extracted from
/// AppDelegate's `servicePathURLs`: the `@objc openWindow`/`openTab`
/// selector targets must stay in the app target (AppKit dispatches the
/// service to them), so they own the pasteboard hand-off and the live-window
/// routing, but they depend on this seam to turn the pasteboard into URLs.
/// Production uses ``ServiceOpenPasteboardResolver``; tests inject a fake.
///
/// The returned URLs are exactly what the legacy helper produced (the
/// directly-carried file URLs when present, otherwise the raw-string lines
/// parsed into file URLs); classification into directories versus files
/// happens afterward in the workspaces domain, not here.
@MainActor
public protocol ServiceOpenResolving {
    /// Resolves the ordered candidate path URLs from `pasteboard`.
    /// - Parameter pasteboard: The Finder NSServices pasteboard.
    /// - Returns: The directly-carried file URLs when the pasteboard has any,
    ///   otherwise the non-empty `.string` representation split on newlines
    ///   and parsed into file URLs; an empty array when neither is present.
    func pathURLs(from pasteboard: NSPasteboard) -> [URL]
}
