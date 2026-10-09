import AppKit

// The seam for cmux-next (appkit-native/SIDEBAR.md): a SidebarController shows a
// SidebarDataSource's snapshot and reports through a SidebarDelegate. No global state: every
// cache below belongs to one controller.

/// Supplies the list. Called on the main thread; the snapshot is a value, so search reads it
/// on a background queue.
protocol SidebarDataSource: AnyObject {
    func sidebarSnapshot(_ sidebar: SidebarController) -> ConversationListSnapshot
}

/// What the list asks its owner to do. The owner changes its data and calls
/// `SidebarController.reloadData()`; the list never changes the data itself.
protocol SidebarDelegate: AnyObject {
    /// The selection changed (click, keyboard, search). Called once per change, in the same
    /// main-thread turn that moved the highlight.
    func sidebar(_ sidebar: SidebarController, didSelect id: ConversationID?)
    func sidebar(_ sidebar: SidebarController, setPinned pinned: Bool, for id: ConversationID)
    func sidebar(_ sidebar: SidebarController, setRead read: Bool, for id: ConversationID)
    func sidebar(_ sidebar: SidebarController, setMuted muted: Bool, for id: ConversationID)
    func sidebar(_ sidebar: SidebarController, delete id: ConversationID)
    // v1.1 (defaults in the extension below).
    func sidebar(_ sidebar: SidebarController, actionsFor id: ConversationID) -> SidebarActions
    func sidebar(_ sidebar: SidebarController, menuItemsFor id: ConversationID) -> [NSMenuItem]
}

/// v1.1: the context-menu actions an owner supports for one conversation. An action that is
/// not in the set has no menu item.
struct SidebarActions: OptionSet {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }
    /// Pin / Unpin (`setPinned`).
    static let pin = SidebarActions(rawValue: 1 << 0)
    /// Mark as Read / Mark as Unread (`setRead`).
    static let markRead = SidebarActions(rawValue: 1 << 1)
    /// Hide Alerts / Show Alerts (`setMuted`).
    static let mute = SidebarActions(rawValue: 1 << 2)
    /// Delete Conversation… (`delete`).
    static let delete = SidebarActions(rawValue: 1 << 3)
    static let all: SidebarActions = [.pin, .markRead, .mute, .delete]
}

/// v1.1: a context-menu item that runs a closure (for `menuItemsFor`).
final class SidebarMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.image = image
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func run() { handler() }
}

/// v1.1: one row of a host's extra search section.
struct SidebarSearchResult: Equatable {
    /// The host's id (any string; it is not a conversation id).
    var id: String
    var title: String
    var subtitle: String
    var avatar: AvatarSpec
    init(id: String, title: String, subtitle: String = "", avatar: AvatarSpec) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.avatar = avatar
    }
}

/// v1.1: a host's extra search section, shown under the matching conversations with its title.
struct SidebarSearchSection: Equatable {
    var title: String
    var results: [SidebarSearchResult]
    init(title: String, results: [SidebarSearchResult]) { self.title = title; self.results = results }
}

/// v1.1: one query to a `SidebarSearchProvider`. Answer once, from any thread, with
/// `complete(_:)`. The next keystroke cancels it (`isCancelled` turns true and a later answer
/// is dropped), so a long search should check `isCancelled` and stop.
final class SidebarSearchRequest: @unchecked Sendable {
    let query: String
    private let lock = NSLock()
    private var cancelled = false
    private var handler: ((SidebarSearchSection?) -> Void)?
    init(query: String, handler: @escaping (SidebarSearchSection?) -> Void) { self.query = query; self.handler = handler }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; handler = nil; lock.unlock() }
    /// The section for this query (nil or no results: no section). Any thread; once.
    func complete(_ section: SidebarSearchSection?) {
        lock.lock(); let h = cancelled ? nil : handler; handler = nil; lock.unlock()
        h?(section)
    }
}

/// v1.1: extra search results from the host (`SidebarController.searchProvider`).
protocol SidebarSearchProvider: AnyObject {
    /// A new non-empty query (main thread). Answer through `request.complete(_:)`.
    func sidebar(_ sidebar: SidebarController, search request: SidebarSearchRequest)
    /// The user selected one of the section's rows (click, Up/Down, Return in the search field).
    /// The delegate's `didSelect` is not called for these rows, and `selectedID` is nil while
    /// one is selected.
    func sidebar(_ sidebar: SidebarController, didSelectSearchResult id: String)
}

extension SidebarDelegate {
    /// v1.1: the menu actions for `id` (default: all). Leave one out to hide its item.
    func sidebar(_ sidebar: SidebarController, actionsFor id: ConversationID) -> SidebarActions { .all }
    /// v1.1: extra context-menu items for `id`, shown after the built-in ones (default: none).
    /// The host sets each item's title, target and action (or a closure-based subclass).
    func sidebar(_ sidebar: SidebarController, menuItemsFor id: ConversationID) -> [NSMenuItem] { [] }
    /// v1.1: pinning is optional too (a host without pins leaves `.pin` out of the actions).
    func sidebar(_ sidebar: SidebarController, setPinned pinned: Bool, for id: ConversationID) {}
    func sidebar(_ sidebar: SidebarController, setRead read: Bool, for id: ConversationID) {}
    func sidebar(_ sidebar: SidebarController, setMuted muted: Bool, for id: ConversationID) {}
    func sidebar(_ sidebar: SidebarController, delete id: ConversationID) {}
}

/// v1.1: where the sidebar's strings come from. Every sidebar string is in one catalog,
/// `SidebarLocalizable.xcstrings` (stable `sidebar.*` keys, an English comment per key). A host
/// copies that file into its resources and points `bundle` at them (a Swift package:
/// `Bundle.module`). Default: the bundle that contains the sidebar code, not `Bundle.main`.
enum SidebarLocalization {
    static var bundle: Bundle = Bundle(for: SidebarController.self)
    /// The catalog's table name (its file name without the extension).
    static var table = "SidebarLocalizable"
    /// The string for `key` in the user's preferred language; `english` if the key is missing.
    static func string(_ key: String, _ english: String) -> String {
        bundle.localizedString(forKey: key, value: english, table: table)
    }
}

/// The sidebar's user-facing strings (SidebarLocalizable.xcstrings, through SidebarLocalization).
enum SidebarStrings {
    /// v1: the table name; v1.1 forwards it to `SidebarLocalization.table`.
    static var table: String {
        get { SidebarLocalization.table }
        set { SidebarLocalization.table = newValue }
    }
    private static func s(_ key: String, _ english: String) -> String { SidebarLocalization.string(key, english) }

    static var search: String { s("sidebar.search", "Search") }
    static var yesterday: String { s("sidebar.yesterday", "Yesterday") }
    static var pin: String { s("sidebar.menu.pin", "Pin") }
    static var unpin: String { s("sidebar.menu.unpin", "Unpin") }
    static var markRead: String { s("sidebar.menu.markRead", "Mark as Read") }
    static var markUnread: String { s("sidebar.menu.markUnread", "Mark as Unread") }
    static var hideAlerts: String { s("sidebar.menu.hideAlerts", "Hide Alerts") }
    static var showAlerts: String { s("sidebar.menu.showAlerts", "Show Alerts") }
    static var delete: String { s("sidebar.menu.delete", "Delete Conversation…") }
    static var noResults: String { s("sidebar.noResults", "No Results") }
    static var conversations: String { s("sidebar.list", "Conversations") }
    static var pinned: String { s("sidebar.pinned", "Pinned") }
    static var typing: String { s("sidebar.typing", "Typing") }
    /// "%d unread messages" (accessibility).
    static var unreadFormat: String { s("sidebar.unread", "%d unread") }
    static var muted: String { s("sidebar.muted", "Alerts hidden") }
    static var image: String { s("sidebar.preview.image", "Image") }

    /// The reaction preview: "Lucas loved “…”", "Loved “…”" (from me in a 1:1, the sender
    /// is left out as Messages does), or "Lucas reacted 🔥 to “…”".
    static func reaction(_ r: ReactionSummary) -> String {
        let t = "“" + r.target + "”"
        if let who = r.senderName {
            switch r.kind {
            case "love": return String(format: s("sidebar.reaction.love.other", "%1$@ loved %2$@"), who, t)
            case "like": return String(format: s("sidebar.reaction.like.other", "%1$@ liked %2$@"), who, t)
            case "dislike": return String(format: s("sidebar.reaction.dislike.other", "%1$@ disliked %2$@"), who, t)
            case "laugh": return String(format: s("sidebar.reaction.laugh.other", "%1$@ laughed at %2$@"), who, t)
            case "emphasize": return String(format: s("sidebar.reaction.emphasize.other", "%1$@ emphasized %2$@"), who, t)
            case "question": return String(format: s("sidebar.reaction.question.other", "%1$@ questioned %2$@"), who, t)
            default: return String(format: s("sidebar.reaction.emoji.other", "%1$@ reacted %2$@ to %3$@"), who, r.kind, t)
            }
        }
        switch r.kind {
        case "love": return String(format: s("sidebar.reaction.love.me", "Loved %@"), t)
        case "like": return String(format: s("sidebar.reaction.like.me", "Liked %@"), t)
        case "dislike": return String(format: s("sidebar.reaction.dislike.me", "Disliked %@"), t)
        case "laugh": return String(format: s("sidebar.reaction.laugh.me", "Laughed at %@"), t)
        case "emphasize": return String(format: s("sidebar.reaction.emphasize.me", "Emphasized %@"), t)
        case "question": return String(format: s("sidebar.reaction.question.me", "Questioned %@"), t)
        default: return String(format: s("sidebar.reaction.emoji.me", "Reacted %1$@ to %2$@"), r.kind, t)
        }
    }
}

/// Geometry of the list and the pinned grid, in points. Each value names its source in
/// appkit-native/SIDEBAR.md ("public-source" or "to verify against a real reference").
struct SidebarMetrics: Equatable {
    // Width. The host owns the width, its storage and its reset; the list reads only the
    // width it gets and reports these two (SidebarController.minimumWidth / preferredWidth).
    static let preferredWidth: CGFloat = 320
    /// Narrowest useful width: the compact list (avatar only) with its margins.
    static let minimumWidth: CGFloat = 76
    /// Below this the list is compact: avatars only, pinned avatars in one column, no names.
    static let compactBelow: CGFloat = 180
    /// A pinned column needs this much width: 3 columns from 260 pt, 2 from 180 pt.
    static let minTileWidth: CGFloat = 80
    /// The pinned avatar at the column-count changes (no size jump between layouts).
    static let pinMinAvatar: CGFloat = 52

    // Top area: the titlebar strip with the window buttons, then the search field.
    static let titlebar: CGFloat = 52
    static let searchInsetX: CGFloat = 10
    static let searchHeight: CGFloat = 30
    static let searchBottomGap: CGFloat = 10

    // Rows.
    static let rowHeight: CGFloat = 72
    static let selectionInsetX: CGFloat = 10
    static let selectionRadius: CGFloat = 10
    static let dotDiameter: CGFloat = 10
    static let dotCenterX: CGFloat = 19
    static let avatar: CGFloat = 40
    static let avatarX: CGFloat = 28
    static let textX: CGFloat = 80
    static let textRightInset: CGFloat = 20
    static let nameBaseline: CGFloat = 23
    static let previewBaseline: CGFloat = 40
    static let previewLineHeight: CGFloat = 16
    static let separatorInsetRight: CGFloat = 10
    static let nameSize: CGFloat = 13
    static let previewSize: CGFloat = 13
    static let timeSize: CGFloat = 12
    static let timeGap: CGFloat = 6

    // Pinned grid.
    static let pinColumns = 3
    static let pinInsetX: CGFloat = 10
    static let pinTopPad: CGFloat = 12
    static let pinMaxAvatar: CGFloat = 76
    static let pinAvatarSideInset: CGFloat = 14
    static let pinNameSize: CGFloat = 11
    static let pinNameGap: CGFloat = 6
    static let pinNameHeight: CGFloat = 16
    static let pinBottomPad: CGFloat = 8
    static let pinSelectionRadius: CGFloat = 12
    static let pinSectionBottom: CGFloat = 6

    var width: CGFloat

    /// The row avatar's x: the measured column, or centered in the compact list.
    var rowAvatarX: CGFloat { compact ? ((width - Self.avatar) / 2).rounded() : Self.avatarX }
    var dotCenterX: CGFloat { compact ? max(Self.dotDiameter / 2 + 1, rowAvatarX - 9) : Self.dotCenterX }
    /// The row text's width (name, preview) at this list width.
    var textWidth: CGFloat { max(0, width - Self.textX - Self.textRightInset) }

    /// Avatar-only rows and a one-column pinned list without names.
    var compact: Bool { width < Self.compactBelow }
    /// 3 at normal widths, 2 when 3 do not fit, 1 in the compact list.
    var columns: Int {
        if compact { return 1 }
        return max(1, min(Self.pinColumns, Int((width - 2 * Self.pinInsetX) / Self.minTileWidth)))
    }
    var tileWidth: CGFloat { ((width - 2 * Self.pinInsetX) / CGFloat(columns)).rounded(.down) }
    /// Grows with the tile in the 3-column grid, from 52 pt at its narrowest to 76 pt; with fewer
    /// columns it stays at 52 pt, so a column change moves tiles but never resizes them.
    var pinAvatar: CGFloat {
        let fit = (tileWidth - 2 * Self.pinAvatarSideInset).rounded()
        if compact { return min(Self.pinMinAvatar, max(36, width - 24)).rounded() }
        return columns == Self.pinColumns ? min(Self.pinMaxAvatar, max(Self.pinMinAvatar, fit)) : Self.pinMinAvatar
    }
    var tileHeight: CGFloat {
        compact ? Self.pinTopPad / 2 + pinAvatar + Self.pinBottomPad
            : Self.pinTopPad + pinAvatar + Self.pinNameGap + Self.pinNameHeight + Self.pinBottomPad
    }
    func pinnedHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = (count + columns - 1) / columns
        return CGFloat(rows) * tileHeight + Self.pinSectionBottom
    }
    func tileRect(_ i: Int) -> CGRect {
        let cols = columns
        let r = i / cols, c = i % cols
        let tw = tileWidth
        let used = tw * CGFloat(cols)
        let x0 = ((width - used) / 2).rounded()
        return CGRect(x: x0 + CGFloat(c) * tw, y: CGFloat(r) * tileHeight, width: tw, height: tileHeight)
    }
}

/// Colors resolved for one appearance and window state (CGColors: the background renderer
/// reads them off the main thread).
struct SidebarPalette: Equatable {
    var dark: Bool
    var name: CGColor
    var secondary: CGColor
    var separator: CGColor
    var unread: CGColor
    var accent: CGColor
    var selectionActive: CGColor
    var selectionInactive: CGColor
    var hover: CGColor
    var selectedText: CGColor
    var monogramTop: CGColor
    var monogramBottom: CGColor
    var groupDisc: CGColor
    var bubble: CGColor
    var bubbleText: CGColor
    var typingDot: CGColor

    /// `unreadColor`, `selectionColor`: the host's colors (v1.1; nil: the system's). Each is
    /// taken only as a CGColor resolved in `appearance` (no component of an NSColor is read, so
    /// catalog, pattern and gray colors are safe).
    static func resolve(_ appearance: NSAppearance, unreadColor: NSColor? = nil, selectionColor: NSColor? = nil) -> SidebarPalette {
        // cmux: no IUO (crash program). The block runs synchronously, so `palette` is set;
        // without it the palette resolves in the current appearance.
        var palette: SidebarPalette?
        func build() -> SidebarPalette {
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            func p3(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
                CGColor(colorSpace: SidebarDraw.p3, components: [r / 255, g / 255, b / 255, a])
                    ?? CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) // cmux: no force unwrap
            }
            return SidebarPalette(
                dark: dark,
                name: NSColor.labelColor.cgColor,
                secondary: NSColor.secondaryLabelColor.cgColor,
                separator: NSColor.separatorColor.cgColor,
                unread: (unreadColor ?? NSColor.systemBlue).cgColor,
                accent: (selectionColor ?? NSColor.controlAccentColor).cgColor,
                selectionActive: (selectionColor ?? NSColor.selectedContentBackgroundColor).cgColor,
                selectionInactive: NSColor.unemphasizedSelectedContentBackgroundColor.cgColor,
                hover: NSColor.labelColor.withAlphaComponent(dark ? 0.07 : 0.05).cgColor,
                selectedText: NSColor.alternateSelectedControlTextColor.cgColor,
                // Contacts' monogram disc (grey gradient, white initials): to verify.
                monogramTop: dark ? p3(132, 136, 145) : p3(166, 171, 184),
                monogramBottom: dark ? p3(104, 108, 117) : p3(134, 139, 151),
                groupDisc: dark ? p3(72, 72, 74) : p3(209, 209, 214),
                // Messages' incoming bubble grey (the transcript palette, dark 59/59/61) for the
                // pinned preview bubble; light: #E9E9EB (the transcript's light link card).
                bubble: dark ? p3(59, 59, 61) : p3(233, 233, 235),
                bubbleText: dark ? p3(255, 255, 255) : p3(0, 0, 0),
                typingDot: dark ? p3(150, 150, 154) : p3(142, 142, 147))
        }
        appearance.performAsCurrentDrawingAppearance { palette = build() }
        return palette ?? build()
    }
}
