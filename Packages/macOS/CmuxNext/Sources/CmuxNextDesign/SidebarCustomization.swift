public import AppKit
public import CmuxNextDesignTokens

/// What a user customization draws in the sidebar (the sidebar hosts it; the app platform
/// renders it) (cx-swovq.1, cx-swovq.2; Lawrence 2026-10-14:
/// the app platform is the engine). The app layer implements it from the user's own app
/// (`cmux.hovercard/1`, `cmux.sidebar.rows/1`); the sidebar only hosts what it renders, so the
/// script, its sandbox and its data stay with the daemon's app host.
@MainActor
public protocol SidebarCustomization: AnyObject {
    /// The custom hover card for `workspace`, mounted now; nil when no app draws one.
    func hoverCard(forWorkspace id: String, card: SidebarCardFacts) -> (any SidebarCustomContent)?
    /// Each decorated row's overrides, by workspace id; rows absent keep the defaults.
    var rowDecorations: [String: SidebarRowDecoration] { get }
    /// Runs when `rowDecorations` changed.
    var onRowDecorationsChange: (() -> Void)? { get set }
}

/// One mounted custom view (a hover card): its view, whether its first scene arrived, and why it
/// failed. The sidebar shows the built-in card with `errorText` while it fails or loads.
@MainActor
public protocol SidebarCustomContent: AnyObject {
    var view: NSView { get }
    var isReady: Bool { get }
    var errorText: String? { get }
    /// Runs when the view, its content, readiness or error changed.
    var onChange: (() -> Void)? { get set }
    /// The view's height laid out `width` points wide (wrapped text included).
    func preferredHeight(width: CGFloat) -> CGFloat
    /// Ends the mount (the card hid or moved to another row).
    func release()
}

/// A row's overrides from `cmux.sidebar.rows/1`. Defaults (no decoration): no icon, regular weight,
/// the shared indicator.
public nonisolated struct SidebarRowDecoration: Hashable, Sendable {
    /// The row's icon as the shared icon wire string (an SF Symbol name or one emoji; a
    /// browser row keeps its favicon).
    public var icon: String?
    /// The title's weight.
    public var weight: Weight?
    /// The loading indicator's style (`none` hides it; waiting, error and done marks stay).
    public var indicator: StatusIndicatorStyle?
    /// Short text the row shows as its status line.
    public var badge: String?

    public enum Weight: String, Hashable, Sendable {
        case regular, medium, semibold, bold

        public var font: NSFont.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    public init(icon: String? = nil, weight: Weight? = nil, indicator: StatusIndicatorStyle? = nil, badge: String? = nil) {
        self.icon = icon
        self.weight = weight
        self.indicator = indicator
        self.badge = badge
    }

    /// Reads one decoration node's props (`row` or `title`, `icon`, `weight`, `indicator`,
    /// `badge`); the key is the row id, or `title:<title>` for a row named by its title. Nil
    /// without either. Unknown values are ignored, never fatal.
    public static func parse(_ props: [String: String]) -> (String, SidebarRowDecoration)? {
        let row = props["row"].flatMap { $0.isEmpty ? nil : $0 } ?? props["title"].flatMap { $0.isEmpty ? nil : "title:" + $0 }
        guard let row else { return nil }
        var decoration = SidebarRowDecoration()
        decoration.icon = props["icon"].flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
        decoration.weight = props["weight"].flatMap(Weight.init(rawValue:))
        decoration.indicator = props["indicator"].flatMap { $0 == "default" ? nil : StatusIndicatorStyle(rawValue: $0) }
        decoration.badge = props["badge"].flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }
        return (row, decoration)
    }
}


/// What the built-in hover card shows, handed to the user's card as `ctx.card` so it can reorder,
/// hide or restyle the same fields without fetching anything (cx-swovq.1).
public nonisolated struct SidebarCardFacts: Hashable, Sendable {
    public struct Fact: Hashable, Sendable {
        /// `needsInput`, `notification`, `unread`, `agent`, `task`, `lastReply`, `presence`, `command`, `folder`, `branch`,
        /// `pullRequest`, `machine`, `status` (a reported status entry), `more` or `needsYou`. `branch` reads with its
        /// repository when known ("cmux · main"), and then no `folder` shows; a home folder shows none.
        public var kind: String
        public var text: String
        /// A running fact's start (Unix ms): the card adds a live elapsed time.
        public var sinceMs: Double?

        public init(kind: String, text: String, sinceMs: Double? = nil) {
            self.kind = kind
            self.text = text
            self.sinceMs = sinceMs
        }
    }

    public var title: String
    /// The status word ("Agent running", "Needs input"); nil while idle.
    public var status: String?
    /// When that status began (Unix ms).
    public var statusSinceMs: Double?
    /// How long ago the workspace was last active ("4w").
    public var age: String?
    public var facts: [Fact]

    public init(title: String, status: String? = nil, statusSinceMs: Double? = nil, age: String? = nil, facts: [Fact] = []) {
        self.title = title
        self.status = status
        self.statusSinceMs = statusSinceMs
        self.age = age
        self.facts = facts
    }
}
