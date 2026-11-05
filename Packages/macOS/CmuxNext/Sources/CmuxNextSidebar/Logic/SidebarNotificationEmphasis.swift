public import CmuxNextDesign
import AppKit

/// How loudly a workspace row says it has something for the person (Debug Settings
/// `sidebar.notificationEmphasis`). Aziz 2026-11-05: the trailing 8 pt dot "doesn't capture my
/// attention enough". `standard` keeps that dot alone (the shipped look); the other three add to it
/// so a row with a notification reads from across the sidebar. Each one keeps the row's height and
/// the trailing column, so switching never moves a row. The person picks one in dogfood.
///
/// A row has a notification when its badge says unread (blue), needs you (orange) or failed (red)
/// (`WorkspaceRowAttention`); work in progress and an already-read finished row are not one.
public nonisolated enum SidebarNotificationEmphasis: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The trailing dot only (the look before).
    case standard
    /// A 3 pt bar down the row's leading edge and a faint wash of the row, both in the dot's color.
    case edgeBar
    /// The name in semibold, and a filled pill with the unread count in place of the dot.
    case boldPill
    /// A larger dot with a soft halo that breathes until the row is read (still under Reduce Motion).
    case halo

    public var tunableTitle: String {
        switch self {
        case .standard: "Dot only (current)"
        case .edgeBar: "Edge bar and wash"
        case .boldPill: "Bold name and count pill"
        case .halo: "Pulsing halo"
        }
    }

    public static let tunable = Tunable<SidebarNotificationEmphasis>.choice(
        "sidebar.notificationEmphasis", .sidebar, "Notification emphasis",
        help: "How a workspace row with a notification stands out: the trailing dot only, an edge bar with a wash, a bold name with a count pill, or a pulsing halo around the dot.",
        default: .standard, code: "SidebarNotificationEmphasis.tunable")
}

/// What a row's emphasis shows: its kind and the count the pill says. nil: nothing waits.
nonisolated struct WorkspaceRowAttention: Equatable {
    enum Kind: Equatable { case unread, needsYou, failed }

    var kind: Kind
    /// Unread items; 0 for a row that only needs you or failed.
    var count: Int

    /// The one state the row's badge says without detailed icons (`WorkspaceRowBadges.simple`),
    /// when it is something for the person.
    init?(_ badges: WorkspaceRowBadges) {
        switch WorkspaceRowBadges.simple(badges.pending) {
        case .error?: kind = .failed
        case .waiting?: kind = .needsYou
        case .success? where badges.unreadCount > 0: kind = .unread
        default: return nil
        }
        count = badges.unreadCount
    }

    /// The badge's own color, so the emphasis and the dot agree (Lawrence msg 11983).
    @MainActor var color: NSColor {
        switch kind {
        case .unread: Palette.statusUnread
        case .needsYou: Palette.statusAttention
        case .failed: Palette.statusError
        }
    }

    /// The pill's text: the count, capped, or "!" for a row that needs you or failed with nothing unread.
    var pillText: String {
        count > 0 ? (count > 99 ? "99+" : String(count)) : "!"
    }
}
