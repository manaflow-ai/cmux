public import AppKit

/// The media hub's cards, kept per tab between opens: an open updates the cards it has and
/// builds only new ones (u2426: the hub built every card, with its four buttons, on each click).
/// One per toolbar (`BrowserToolbarButtonsView.mediaRows`).
@MainActor
public final class BrowserMediaRows {
    /// One card to show.
    public struct Card {
        public var key: String
        public var title: String
        public var subtitle: String
        public var media: BrowserMediaState
        public var artwork: NSImage?
        /// The card offers Picture in Picture for a video (`media.pictureInPicture.enabled`), read
        /// when the card draws and when its button is pressed.
        public var pictureInPicture: () -> Bool
        public var onCommand: (BrowserMediaCommand) -> Void
        public var onReveal: () -> Void

        public init(key: String, title: String, subtitle: String, media: BrowserMediaState, artwork: NSImage?, pictureInPicture: @escaping () -> Bool = { true },
                    onCommand: @escaping (BrowserMediaCommand) -> Void, onReveal: @escaping () -> Void) {
            self.key = key
            self.title = title
            self.subtitle = subtitle
            self.media = media
            self.artwork = artwork
            self.pictureInPicture = pictureInPicture
            self.onCommand = onCommand
            self.onReveal = onReveal
        }
    }

    private var rows: [String: BrowserMediaRowView] = [:]
    /// Cards built since this cache was made (a test seam: a second open builds none).
    public private(set) var built = 0

    public init() {}

    /// The views for `cards`, in order: a card shown before is updated in place; cards of tabs
    /// no longer listed go.
    public func views(_ cards: [Card]) -> [BrowserMediaRowView] {
        var next: [String: BrowserMediaRowView] = [:]
        let views = cards.map { card in
            let row: BrowserMediaRowView
            if let existing = rows[card.key] {
                existing.show(title: card.title, subtitle: card.subtitle, media: card.media, artwork: card.artwork,
                              pictureInPicture: card.pictureInPicture, onCommand: card.onCommand, onReveal: card.onReveal)
                row = existing
            } else {
                built += 1
                row = BrowserMediaRowView(title: card.title, subtitle: card.subtitle, media: card.media, artwork: card.artwork,
                                          pictureInPicture: card.pictureInPicture, onCommand: card.onCommand, onReveal: card.onReveal)
            }
            // A view belongs to one menu item: the last menu's item lets go of it.
            row.enclosingMenuItem?.view = nil
            next[card.key] = row
            return row
        }
        rows = next
        return views
    }

    /// The media hub menu of `cards`, or one disabled `empty` row.
    public func menu(_ cards: [Card], empty: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if cards.isEmpty {
            let item = NSMenuItem(title: empty, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for (index, view) in views(cards).enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
        }
        return menu
    }
}
