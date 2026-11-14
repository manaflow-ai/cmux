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
}
