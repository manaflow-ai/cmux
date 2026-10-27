/// When an ``EventSubscription``'s handler runs.
public enum EventDelivery: Sendable {
    /// Only while the subscriber's ``VisibilityNode`` renders (``VisibilityNode/wantsFrames``: it is
    /// visible, or a capture vote holds it, so a screenshot of a hidden tab draws current views).
    /// Posts that arrive while it does not make one ``EventCall/missed`` call when it next renders,
    /// however many came.
    case whenVisible
    /// On every post, shown or not: work the person waits for even with the view hidden (a model
    /// write, a capture another window shows).
    case always
}

/// Why an ``EventSubscription``'s handler runs.
public enum EventCall: Sendable, Equatable {
    /// The notification was posted.
    case posted
    /// The subscriber's node just started rendering and the notification was posted while it did
    /// not: read the current state, the posts themselves are gone.
    case missed
}
