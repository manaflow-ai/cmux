import AppKit

/// The hover card gallery: each card module registers its kinds over fixture data (the sidebar's
/// session cards, the tab strip's cards) and `debug.hover_cards {gallery: set}` shows one set in a
/// child window over the main window, so the macOS tour's `hover-card` shots include it (the
/// native cards have no Linux gallery). It lives outside CmuxNextApp, which may not grow
/// (scripts/cmux-next/check-app-size.sh). A Release build registers nothing and shows nothing.
@MainActor
public struct HoverCardGallery {
    public typealias Cards = () -> [(name: String, view: NSView)]

    private static var sets: [String: Cards] = [:]
    private static var window: NSWindow?

    public init() {}

    /// Adds `set`; the card controllers call it as they start (DEBUG builds only).
    public static func register(_ set: String, cards: @escaping Cards) {
        #if DEBUG
        sets[set] = cards
        #endif
    }

    /// Shows `set` over the main window in its theme (`"none"` closes the gallery), or nil when no
    /// gallery was asked for. The answer says `ok` false when the set or the window is missing.
    public static func show(_ set: String?) -> [String: String]? {
        guard let set else { return nil }
        if let window {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
        window = nil
        if set == "none" { return ["ok": "true", "set": set] }
        #if DEBUG
        guard let cards = sets[set]?(),
              let parent = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.parent == nil }),
              let content = parent.contentView else { return ["ok": "false", "set": set] }
        let frame = parent.convertToScreen(content.convert(content.bounds, to: nil))
        let shown = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        shown.isReleasedWhenClosed = false
        shown.isOpaque = false
        shown.backgroundColor = .clear
        shown.hasShadow = false
        shown.ignoresMouseEvents = true
        shown.adoptThemeScope(of: content)
        shown.contentView = grid(cards)
        parent.addChildWindow(shown, ordered: .above)
        window = shown
        return ["ok": "true", "set": set, "cards": String(cards.count)]
        #else
        return ["ok": "false", "set": set]
        #endif
    }

    /// The cards three to a row, each named above its glass card, from the top-left corner.
    private static func grid(_ cards: [(name: String, view: NSView)]) -> NSView {
        let rows = stride(from: 0, to: cards.count, by: 3).map { start -> NSView in
            let row = NSStackView(views: cards[start..<min(start + 3, cards.count)].map(cell))
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = Metrics.space6
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let page = NSView()
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: Metrics.space6),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: Metrics.space6),
        ])
        return page
    }

    private static func cell(_ card: (name: String, view: NSView)) -> NSView {
        let label = ThemedLabel(labelWithString: card.name)
        label.font = Typography.caption
        let stack = NSStackView(views: [label, card.view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
        return stack
    }
}
