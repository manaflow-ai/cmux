public import Foundation

/// One card of the stack above the sidebar's bottom band (R114): the
/// update, what's new, and cmux announcements. The App supplies the text;
/// the sidebar renders and reports actions.
public nonisolated struct SidebarCard: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var detail: String?
    /// 0...1 for a progress bar, nil for none.
    public var progress: Double?
    /// Small text buttons under the detail (e.g. Install Now, Later).
    public var buttons: [Button]
    /// Shows an x on hover that reports ``SidebarCardAction/dismiss``.
    public var dismissible: Bool
    /// False: shown only while the pointer is over the sidebar (R100
    /// footer); announcements. True: the update and what's new.
    public var alwaysVisible: Bool

    public struct Button: Hashable, Sendable {
        public var id: String
        public var title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public init(id: String, title: String, detail: String? = nil, progress: Double? = nil, buttons: [Button] = [],
                dismissible: Bool = false, alwaysVisible: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.progress = progress
        self.buttons = buttons
        self.dismissible = dismissible
        self.alwaysVisible = alwaysVisible
    }
}

/// What a card reports.
public nonisolated enum SidebarCardAction: Hashable, Sendable {
    /// A click on the card's body.
    case open
    case button(String)
    case dismiss
}
