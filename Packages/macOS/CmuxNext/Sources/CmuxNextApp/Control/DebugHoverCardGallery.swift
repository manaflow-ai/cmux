#if DEBUG
import AppKit
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTabs

/// DEBUG ONLY: `debug.hover_card_gallery {set: "sidebar" | "tabs"}` opens the hover cards in each of
/// their kinds over fixture data (`WorkspaceHoverCardGallery`, `TabHoverCardGallery`) as an
/// internal page tab of the active window, each on the shared overlay glass (`OverlaySurfaceView`)
/// in the window's theme, for the macOS tour's `hover-card` shots (the native cards have no Linux
/// gallery). Compiled out of Release with this whole file.
extension InternalPageID {
    static let hoverCardGallery = InternalPageID(rawValue: "hover-card-gallery")
}

@MainActor
final class DebugHoverCardGallery: InternalPageProvider {
    /// The set the next page shows.
    var nextSet = "sidebar"

    var page: InternalPageID { .hoverCardGallery }
    var title: String { "Hover cards" }
    var symbol: String { "rectangle.on.rectangle" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let cards = nextSet == "tabs" ? TabHoverCardGallery.cards() : WorkspaceHoverCardGallery.cards()
        return Self.grid(cards)
    }

    /// The cards three to a row, each named above its glass card, top-left aligned.
    static func grid(_ cards: [(name: String, view: NSView)]) -> NSView {
        let columns = stride(from: 0, to: cards.count, by: 3).map { Array(cards[$0..<min($0 + 3, cards.count)]) }
        let rows = columns.map { chunk -> NSView in
            let row = NSStackView(views: chunk.map(cell))
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

    static func open(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        if services.pages.provider(.hoverCardGallery) == nil { services.pages.register(DebugHoverCardGallery()) }
        let set = params["set"]?.stringValue == "tabs" ? "tabs" : "sidebar"
        (services.pages.provider(.hoverCardGallery) as? DebugHoverCardGallery)?.nextSet = set
        let view = services.pages.openNew(.hoverCardGallery, in: services.windows.active, focus: true)
        return .object(["ok": .bool(view != nil), "set": .string(set)])
    }
}
#endif
