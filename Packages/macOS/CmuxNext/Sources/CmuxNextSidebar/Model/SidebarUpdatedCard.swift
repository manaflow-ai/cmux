import Foundation

/// The "cmux Updated!" card above the footer (cx-7py7): after the app
/// updated to a new version, a title with an x and two rows, "See What's
/// New" (`SidebarIntent.openWhatsNew`) and "Share cmux" (`.shareCmux`).
/// The x sends `.dismissUpdated`. It takes the bottom card slot before the
/// tip card (the tip waits); a staged update card wins over it. Text
/// arrives localized.
public nonisolated struct SidebarUpdatedCard: Hashable, Sendable {
    public var title: String
    /// The update's build date (after an update: "Updated to <version>").
    public var detail: String?
    /// The update's first changelog lines.
    public var lines: [String]
    public var whatsNewTitle: String
    public var shareTitle: String
    /// The x's tooltip and VoiceOver label.
    public var dismissLabel: String

    public init(title: String, detail: String? = nil, lines: [String] = [], whatsNewTitle: String, shareTitle: String,
                dismissLabel: String) {
        self.title = title
        self.detail = detail
        self.lines = lines
        self.whatsNewTitle = whatsNewTitle
        self.shareTitle = shareTitle
        self.dismissLabel = dismissLabel
    }
}
