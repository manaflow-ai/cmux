public import Foundation

extension Notification.Name {
    /// Posted to request that the feedback composer be presented (optionally
    /// targeting a specific window passed as the notification `object`). The
    /// raw value matches the app-side declaration so posts from this package and
    /// observers registered in the app interoperate.
    public static let feedbackComposerRequested = Notification.Name("cmux.feedbackComposerRequested")
}
