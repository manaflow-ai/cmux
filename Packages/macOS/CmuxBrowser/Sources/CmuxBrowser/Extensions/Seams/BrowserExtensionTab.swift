/// A browser tab that extension calls can target.
///
/// Chromium addresses extension operations through a live browser of the
/// profile; a tab passes its own identity so options pages and commands land
/// in the tab the person or agent meant. Only Chromium tabs conform; WebKit
/// tabs have no extensions.
@MainActor
public protocol BrowserExtensionTab: AnyObject {
    /// Clicks the toolbar action of `extensionID` in this tab, anchoring its
    /// popup to the pinned button or, when unpinned, the Extensions button.
    ///
    /// - Parameter extensionID: The extension whose action to run.
    func requestExtensionAction(_ extensionID: String)
}
