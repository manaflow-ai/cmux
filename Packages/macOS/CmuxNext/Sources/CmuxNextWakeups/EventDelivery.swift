/// When an ``EventSubscription``'s handler runs.
public enum EventDelivery: Sendable {
    /// Only while the subscriber's ``VisibilityNode`` is visible. Posts that arrive while it is
    /// hidden or occluded make one ``EventCall/missed`` call when it next shows, however many came.
    case whenVisible
    /// On every post, shown or not: work the person waits for even with the view hidden (a model
    /// write, a capture another window shows).
    case always
}

/// Why an ``EventSubscription``'s handler runs.
public enum EventCall: Sendable, Equatable {
    /// The notification was posted.
    case posted
    /// The subscriber's node just showed and the notification was posted while it was not
    /// visible: read the current state, the posts themselves are gone.
    case missed
}
