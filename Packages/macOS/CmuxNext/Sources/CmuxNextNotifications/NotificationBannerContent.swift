/// One system banner's three text lines (``NotificationBannerFormatter``).
package struct NotificationBannerContent: Hashable {
    /// Where: `workspace › tab [· machine]`.
    package var title: String
    /// Who and what state, then the poster's own subtitle; nil when there is neither.
    package var subtitle: String?
    /// What was said, as plain text.
    package var body: String

    package init(title: String, subtitle: String? = nil, body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}
