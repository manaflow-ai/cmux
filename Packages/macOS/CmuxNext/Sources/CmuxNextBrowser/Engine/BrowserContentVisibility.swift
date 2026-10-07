public import AppKit

/// Whether a page is actually on screen where its pane expects it, read
/// from AppKit (for the content invariant and `debug.surfaces`). Reading it
/// changes nothing.
public struct BrowserContentVisibility: Sendable, Equatable {
    /// True when the page draws over its content view.
    public var isVisible: Bool
    /// Why not, when `isVisible` is false (`not_in_window`, `host_hidden`,
    /// `page_window_hidden`, `page_window_misplaced`, `no_page`, ...).
    public var reason: String?

    public init(isVisible: Bool, reason: String? = nil) {
        self.isVisible = isVisible
        self.reason = reason
    }

    public static let visible = BrowserContentVisibility(isVisible: true)
    public static func hidden(_ reason: String) -> BrowserContentVisibility { .init(isVisible: false, reason: reason) }
}

/// Tabs that can report `BrowserContentVisibility`.
public protocol BrowserContentVisibilityReporting: AnyObject {
    @MainActor var contentVisibility: BrowserContentVisibility { get }
}

/// Where browser engines report content lifecycle steps (show, hide, the
/// page window's visibility) for the App's input journal. Main actor only.
@MainActor
public final class BrowserLifecycleTrace {
    private var sink: ((String, String) -> Void)?

    /// The process-wide trace used by default browser hosts.
    public static let shared = BrowserLifecycleTrace()

    /// Creates a lifecycle trace for the containing browser engine.
    ///
    /// - Parameter sink: Receives the tab identifier and lifecycle event, or nil to disable tracing.
    public init(sink: ((String, String) -> Void)? = nil) {
        self.sink = sink
    }

    /// Replaces the process-wide sink configured by the application layer.
    public func configure(sink: ((String, String) -> Void)?) {
        self.sink = sink
    }

    func record(_ tab: BrowserTabID, _ event: String) {
        sink?(tab.rawValue, event)
    }
}
