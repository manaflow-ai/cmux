import CoreGraphics
import Foundation

/// Long-press a Feed row to peek at its chat (the iOS Mail and Messages pattern: press to read in
/// context, let go to stay in the Feed at the same scroll position, tap the preview to open).
///
/// The preview never waits on the network: it draws what the phone already holds. A chat whose
/// transcript is in memory shows its newest turns (your last prompt, the agent's latest
/// messages) with the chat's own views; any other event shows its own text under its place
/// header. There is no spinner and no empty card.
enum FeedPeek {
    enum Content: Equatable, Sendable {
        /// The chat's newest turns, drawn by the chat's own still (`AgentChatPreview`).
        case chat
        /// The event's own markdown under its place header.
        case event
    }

    /// What the preview of an event shows. `loadedTurns`: the turns of its chat the phone holds
    /// in memory now (0: the chat was never opened in this launch, or has none).
    static func content(opensTerminal: Bool, hasLink: Bool, loadedTurns: Int) -> Content {
        // A terminal agent's event and a Mac Feed request have no chat: opening them shows a
        // terminal or a page, so the preview is the event's text.
        if opensTerminal || hasLink { return .event }
        return loadedTurns > 0 ? .chat : .event
    }

    /// The preview's size in a window `container` big: about two thirds of its height, less on a
    /// short screen so the menu under it still fits without the system shrinking the preview.
    /// `fitting`: the content's own height when it is shorter (an event's few lines get a card
    /// their size, never a tall blank one); nil fills the height (a chat).
    static func size(container: CGSize, fitting: CGFloat? = nil) -> CGSize {
        // Capped at a readable column: an unfolded phone's window is about twice a phone's width.
        let width = max(240, min(maxWidth, container.width - 2 * margin))
        let tallest = max(minHeight, min((container.height * 2 / 3).rounded(), container.height - menuReserve))
        guard let fitting else { return CGSize(width: width, height: tallest) }
        return CGSize(width: width, height: min(tallest, max(minHeight, fitting.rounded(.up))))
    }

    static let margin: CGFloat = 16
    static let maxWidth: CGFloat = 560
    static let minHeight: CGFloat = 120
    /// The row menu's five actions and its title, the gap above them and the safe areas.
    static let menuReserve: CGFloat = 340
}
