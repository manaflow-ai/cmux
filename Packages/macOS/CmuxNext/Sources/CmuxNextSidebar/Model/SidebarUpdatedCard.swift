import Foundation

/// The "cmux Updated!" card above the footer (cx-7py7): after the app
/// updated to a new version, a title with an x and "See What's New"
/// (`SidebarIntent.openWhatsNew`). Share cmux is the palette's.
/// The x sends `.dismissUpdated`. It takes the bottom card slot before the
/// tip card (the tip waits); a staged update card wins over it. Text
/// arrives localized.
public nonisolated struct SidebarUpdatedCard: Hashable, Sendable {
    public var title: String
    public var whatsNewTitle: String
    /// The x's tooltip and VoiceOver label.
    public var dismissLabel: String

    public init(title: String, whatsNewTitle: String, dismissLabel: String) {
        self.title = title
        self.whatsNewTitle = whatsNewTitle
        self.dismissLabel = dismissLabel
    }
}
