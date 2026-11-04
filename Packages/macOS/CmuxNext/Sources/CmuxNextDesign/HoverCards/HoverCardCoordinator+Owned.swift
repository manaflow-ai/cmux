public import AppKit
public import CmuxNextDesignTokens

/// A card its owner shows and closes (the sidebar's Update Ready highlights), in the app's one
/// card window: the owner keeps its own open and close rules (its card takes clicks and scrolls),
/// and the coordinator keeps the rule that one card shows at a time.
struct HoverCardOwned {
    let id: HoverTargetID
    /// The card left the window: closed by its owner (after its fade), or taken by a target.
    let ended: @MainActor () -> Void
    /// Its owner closed it; it fades out.
    var ending = false
}

// Lawrence 2026-10-20: "The card for the update ready ... is different from the card that shows
// up for other non-workspaces normally ... Ideally it's the same card and we animate the resizing
// so that only one card ... appears at any point in time." The update card's highlights used to
// open their own window beside this one; now they show in it. Showing them morphs a workspace or
// tab card that shows into them (no second card), and a target the pointer reaches next takes
// the card back at once, morphing again.
extension HoverCardCoordinator {
    /// Shows `body` as `id`'s card in the one card window, beside `anchor` (screen), until its
    /// owner calls ``endOwned(_:)`` or a target takes the card.
    ///
    /// A card that shows (a workspace's, a tab's) morphs into this one; nothing else hides.
    /// Showing the same id again updates it in place.
    ///
    /// - Parameters:
    ///   - id: The owner's card (one per owner).
    ///   - body: The content, its placement, theme anchor and recolor.
    ///   - anchor: What the card describes, on screen.
    ///   - parent: The window the card is a child of.
    ///   - interactive: The card takes clicks and scrolls.
    ///   - ended: Runs once when the card left the window: after its owner's close faded it out,
    ///     or at once when a target took the card (the body is out of the window by then).
    public func presentOwned(_ id: HoverTargetID, body: HoverCardBody, anchor: CGRect, parent: NSWindow,
                             interactive: Bool = true, ended: @escaping @MainActor () -> Void) {
        if let current = owned, current.id != id { finishOwned() }
        let again = owned?.id == id
        owned = HoverCardOwned(id: id, ended: ended)
        send(.owned(true))
        let panel = panel ?? HoverCardPanel()
        self.panel = panel
        panel.present(body: body.view, anchor: anchor, placement: body.placement, parent: parent, themeAnchor: body.themeAnchor,
                      sliding: !again, interactive: interactive, cornerRadius: body.cornerRadius, applyTheme: body.applyTheme)
    }

    /// The owner closes `id`'s card: it fades out, then its `ended` runs. No-op unless it shows.
    public func endOwned(_ id: HoverTargetID) {
        guard var current = owned, current.id == id, !current.ending else { return }
        current.ending = true
        owned = current
        send(.owned(false))
        guard let panel else { return finishOwned() }
        panel.dismiss { [weak self] in
            guard let self, let owned = self.owned, owned.id == id, owned.ending else { return }
            self.finishOwned()
        }
    }

    /// `id`'s content changed size: the card fits it again.
    public func refitOwned(_ id: HoverTargetID, anchor: CGRect? = nil) {
        guard let owned, owned.id == id, !owned.ending, let panel else { return }
        if let anchor { panel.follow(anchor) }
        panel.refit()
    }

    /// Whether `id`'s card shows (and is not closing).
    public func isShowingOwned(_ id: HoverTargetID) -> Bool {
        guard let owned, owned.id == id, !owned.ending else { return false }
        return panel?.isShowingCard == true
    }

    /// `id`'s card's frame on screen while it shows, else nil.
    public func ownedCardFrame(_ id: HoverTargetID) -> CGRect? {
        isShowingOwned(id) ? panel?.cardFrame : nil
    }

    /// The one card window (tests, proofs).
    public var cardWindow: NSWindow? { panel }

    /// The owner's card left the window: its owner hears it once.
    func finishOwned() {
        guard let current = owned else { return }
        owned = nil
        if !current.ending { send(.owned(false)) }
        current.ended()
    }
}
