/// A page that reports whether it plays sound the person hears, as one observable bit that
/// changes only when the sound starts or stops (Chrome's `PageNode::IsAudible` and
/// `PageNodeObserver::OnIsAudibleChanged`, components/performance_manager/public/graph/page_node.h).
///
/// The bit is `BrowserTabState.media?.isAudible`, stored apart from `state`: observing `state`
/// fires on every load-progress tick, title or favicon, while observing this fires on the flip only.
/// The WebKit and Chromium pages and the mock adopt it.
@MainActor
public protocol BrowserAudibleReporting: AnyObject {
    /// The page plays unmuted media now. Observable; written only when it changes.
    var isAudible: Bool { get }
}
