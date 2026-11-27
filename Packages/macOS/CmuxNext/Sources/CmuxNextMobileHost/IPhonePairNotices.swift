public import UserNotifications

/// The banner that tells the person a phone asks to pair while cmux is not in front: one
/// banner at a time (``id``), with Review, which opens Settings > Mobile (``settingsRoute``),
/// where the request waits with Allow and Don't Allow. The app posts it through its own
/// notification center (the center's delegate routes the click). The banner answers nothing.
public struct IPhonePairNotices {
    /// The banner's identifier: a newer request replaces the older banner.
    public nonisolated static let id = "cmux.iphone.pair"
    /// The banner's category, with Review.
    public nonisolated static let category = "cmux.iphone.pair"
    public nonisolated static let reviewAction = "cmux.iphone.pair.review"
    /// Settings > Mobile, where the waiting requests are.
    public nonisolated static let settingsRoute = "#/settings/mobile"

    /// Posts (or replaces) the banner: its title and body.
    public var post: @MainActor (_ title: String, _ body: String) -> Void
    /// Removes the banner: nothing waits any more.
    public var withdraw: @MainActor () -> Void

    public init(post: @escaping @MainActor (_ title: String, _ body: String) -> Void, withdraw: @escaping @MainActor () -> Void) {
        self.post = post
        self.withdraw = withdraw
    }

    /// The banner category; Review brings cmux to the front.
    public static func notificationCategory() -> UNNotificationCategory {
        let review = UNNotificationAction(identifier: reviewAction, title: IPhoneHostStrings.noticeReview, options: [.foreground])
        return UNNotificationCategory(identifier: category, actions: [review], intentIdentifiers: [])
    }
}
