public import Foundation

/// The OS processes that render a page, for the resource hover cards.
/// Engines that cannot tell report nothing.
public protocol BrowserProcessReporting: AnyObject {
    /// What identifies this page's processes right now.
    var contentProcesses: BrowserContentProcesses { get }
}

public enum BrowserContentProcesses: Sendable, Equatable {
    /// Process ids (WebKit's WebContent process).
    case pids([Int32])
    /// Chromium renderer client ids (`--renderer-client-id=`); map them
    /// with ``ChromiumHelperProcess/list()``.
    case chromiumRendererClients([Int32])
    case none
}
