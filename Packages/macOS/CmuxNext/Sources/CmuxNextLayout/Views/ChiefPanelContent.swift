public import AppKit

/// A view the Chief panel (``ChiefPanelView``) may hold that knows whether its Chief is answering.
///
/// The panel holds Home's own view: a conversation's view, or Home's page, which wraps the Messages view that shows
/// one. Each layer conforms and passes the answer through, so the panel asks only the view it holds.
///
/// ```swift
/// extension HomeHostView: ChiefPanelContent {
///     var chiefIsAnswering: Bool { isWorking }
/// }
/// ```
@MainActor
public protocol ChiefPanelContent: AnyObject {
    /// Whether the Chief this view shows is answering now. While it is, Esc in the panel stops the answer instead of
    /// hiding the panel, as Esc does in Home.
    var chiefIsAnswering: Bool { get }
    /// Whether the view leaves its own background clear so the workspace shows through (the see-through styles,
    /// ``ChiefPanelStyle/isSeeThrough``); bubbles, text and the composer still draw. False by default.
    var chiefShowsThrough: Bool { get set }
}

extension ChiefPanelContent {
    /// A view with no clear form keeps its background: setting this does nothing.
    public var chiefShowsThrough: Bool {
        get { false }
        set {}
    }
}
