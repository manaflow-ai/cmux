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
}

extension SidebarDelegate {
    func sidebar(_ sidebar: SidebarController, setRead read: Bool, for id: ConversationID) {}
    func sidebar(_ sidebar: SidebarController, setMuted muted: Bool, for id: ConversationID) {}
    func sidebar(_ sidebar: SidebarController, delete id: ConversationID) {}
}

/// The sidebar's user-facing strings (AppKitNative.xcstrings, English and Japanese). A host
/// that vendors the list copies the `sidebar.*` keys into its own catalog and sets `table`.
enum SidebarStrings {
    static var table = "AppKitNative"

    static var search: String { String(localized: "sidebar.search", defaultValue: "Search", table: table) }
    static var yesterday: String { String(localized: "sidebar.yesterday", defaultValue: "Yesterday", table: table) }
    static var pin: String { String(localized: "sidebar.menu.pin", defaultValue: "Pin", table: table) }
    static var unpin: String { String(localized: "sidebar.menu.unpin", defaultValue: "Unpin", table: table) }
    static var markRead: String { String(localized: "sidebar.menu.markRead", defaultValue: "Mark as Read", table: table) }
    static var markUnread: String { String(localized: "sidebar.menu.markUnread", defaultValue: "Mark as Unread", table: table) }
    static var hideAlerts: String { String(localized: "sidebar.menu.hideAlerts", defaultValue: "Hide Alerts", table: table) }
    static var showAlerts: String { String(localized: "sidebar.menu.showAlerts", defaultValue: "Show Alerts", table: table) }
    static var delete: String { String(localized: "sidebar.menu.delete", defaultValue: "Delete Conversation…", table: table) }
    static var noResults: String { String(localized: "sidebar.noResults", defaultValue: "No Results", table: table) }
    static var conversations: String { String(localized: "sidebar.list", defaultValue: "Conversations", table: table) }
    static var pinned: String { String(localized: "sidebar.pinned", defaultValue: "Pinned", table: table) }
    static var typing: String { String(localized: "sidebar.typing", defaultValue: "Typing", table: table) }
    /// "%d unread messages" (accessibility).
    static var unreadFormat: String { String(localized: "sidebar.unread", defaultValue: "%d unread", table: table) }
    static var muted: String { String(localized: "sidebar.muted", defaultValue: "Alerts hidden", table: table) }
    static var image: String { String(localized: "sidebar.preview.image", defaultValue: "Image", table: table) }

    /// The reaction preview: "Lucas loved “…”", "Loved “…”" (from me in a 1:1, the sender
    /// is left out as Messages does), or "Lucas reacted 🔥 to “…”".
    static func reaction(_ r: ReactionSummary) -> String {
        let t = "“" + r.target + "”"
        if let who = r.senderName {
            switch r.kind {
            case "love": return String(format: String(localized: "sidebar.reaction.love.other", defaultValue: "%1$@ loved %2$@", table: table), who, t)
            case "like": return String(format: String(localized: "sidebar.reaction.like.other", defaultValue: "%1$@ liked %2$@", table: table), who, t)
            case "dislike": return String(format: String(localized: "sidebar.reaction.dislike.other", defaultValue: "%1$@ disliked %2$@", table: table), who, t)
            case "laugh": return String(format: String(localized: "sidebar.reaction.laugh.other", defaultValue: "%1$@ laughed at %2$@", table: table), who, t)
            case "emphasize": return String(format: String(localized: "sidebar.reaction.emphasize.other", defaultValue: "%1$@ emphasized %2$@", table: table), who, t)
            case "question": return String(format: String(localized: "sidebar.reaction.question.other", defaultValue: "%1$@ questioned %2$@", table: table), who, t)
            default: return String(format: String(localized: "sidebar.reaction.emoji.other", defaultValue: "%1$@ reacted %2$@ to %3$@", table: table), who, r.kind, t)
            }
        }
        switch r.kind {
        case "love": return String(format: String(localized: "sidebar.reaction.love.me", defaultValue: "Loved %@", table: table), t)
        case "like": return String(format: String(localized: "sidebar.reaction.like.me", defaultValue: "Liked %@", table: table), t)
        case "dislike": return String(format: String(localized: "sidebar.reaction.dislike.me", defaultValue: "Disliked %@", table: table), t)
        case "laugh": return String(format: String(localized: "sidebar.reaction.laugh.me", defaultValue: "Laughed at %@", table: table), t)
        case "emphasize": return String(format: String(localized: "sidebar.reaction.emphasize.me", defaultValue: "Emphasized %@", table: table), t)
        case "question": return String(format: String(localized: "sidebar.reaction.question.me", defaultValue: "Questioned %@", table: table), t)
        default: return String(format: String(localized: "sidebar.reaction.emoji.me", defaultValue: "Reacted %1$@ to %2$@", table: table), r.kind, t)
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

    static func resolve(_ appearance: NSAppearance) -> SidebarPalette {
        var p: SidebarPalette!
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            func p3(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
                CGColor(colorSpace: SidebarDraw.p3, components: [r / 255, g / 255, b / 255, a])!
            }
            p = SidebarPalette(
                dark: dark,
                name: NSColor.labelColor.cgColor,
                secondary: NSColor.secondaryLabelColor.cgColor,
                separator: NSColor.separatorColor.cgColor,
                unread: NSColor.systemBlue.cgColor,
                accent: NSColor.controlAccentColor.cgColor,
                selectionActive: NSColor.selectedContentBackgroundColor.cgColor,
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
        return p
    }
}
