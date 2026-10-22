/// One system banner's three text lines (``NotificationBannerFormatter``).
struct NotificationBannerContent: Hashable {
    /// Where: `workspace › tab [· machine]`.
    var title: String
    /// Who and what state, then the poster's own subtitle; nil when there is neither.
    var subtitle: String?
    /// What was said, as plain text.
    var body: String
}
