/// The view that stands for one pane tab (or a window's top page) and owns its ``PanePresence``.
///
/// A ``HomeNativeTranscriptView`` takes the presence of its nearest ancestor whose ``panePresence``
/// is not nil, so a container that holds a transcript but is no tab by itself (the Home page's
/// conversation column, the New Message page, the docked Home's Messages view) returns nil and
/// needs no forwarding: its transcripts follow the tab around it.
@MainActor
public protocol PanePresenceHost: AnyObject {
    /// The presence of the tab this view stands for; nil when the view is only a container inside
    /// another tab's content.
    var panePresence: PanePresence? { get }
}
