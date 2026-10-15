import Foundation

/// A ``BrowserPage`` whose engine asks the host to show its page context menu (Chromium), so the
/// panel can add its cmux rows. WebKit pages show their own menu and do not conform.
@MainActor
public protocol BrowserPageContextMenuCustomizing: BrowserPage {
    /// The panel that adds and runs cmux rows; held weakly by conformers.
    var contextMenuHost: (any BrowserContextMenuHosting)? { get set }
}
