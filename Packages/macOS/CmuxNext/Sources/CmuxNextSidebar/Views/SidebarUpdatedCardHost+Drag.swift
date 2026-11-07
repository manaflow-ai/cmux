import AppKit

/// The Updated card's drag (Leo 2026-11-07: "what if you could, like, drag around the updated to
/// nightly, and you can drag that up to the top if you wanted to?"). The card's page runs it (webviews
/// `ui/anchors.ts`, the toasts' anchors and drag): it says how far it holds the card from its rest,
/// and on release the anchor the card settles at; a flick or a drop past the sidebar's edge sends the
/// page's dismiss, the x's path. This view only follows: held, it stands where the page holds it
/// (from where it was shown when the press came, if that was mid-settle);
/// dropped, it springs from where it was let go to its anchor while the list's room moves on its own
/// spring (``SidebarCardSlotMotion``), one transition with nothing popping. The anchor is kept across
/// launches, so the card's first frame is at its place.
extension SidebarUpdatedCardHost {
    static let rememberedAnchorKey = "cmux.sidebar.updatedCard.anchor"

    /// The anchor the card was last dropped at; the bottom slot when it never moved.
    static var rememberedAnchor: SidebarCardAnchor {
        UserDefaults.standard.string(forKey: rememberedAnchorKey).flatMap(SidebarCardAnchor.init(rawValue:)) ?? .bottom
    }

    func pageDragged(_ drag: SidebarCardDrag) {
        guard card != nil else { return }
        guard let drop = drag.drop else {
            if heldOffset == nil {
                // Taken mid-settle: the drag carries on from where the card is shown, never from its rest.
                heldBase = CGPoint(x: settleX.value, y: settleY.value)
                settleX.reset()
                settleY.reset()
            }
            heldOffset = drag.offset
            onHeightChange?()
            return
        }
        // Springs from here to the rest at `drop` (laid out next: the slot moves the list's room).
        droppedAt = frame.origin
        (heldOffset, heldBase) = (nil, .zero)
        if drop != anchor {
            anchor = drop
            let defaults = UserDefaults.standard
            if drop == .bottom { defaults.removeObject(forKey: Self.rememberedAnchorKey) } else { defaults.set(drop.rawValue, forKey: Self.rememberedAnchorKey) }
        }
        onHeightChange?()
    }

    /// The view's frame for a card resting at `rest`: where the page holds it, else on its way from
    /// where it was let go, else at its rest. `sidebar` runs the settle's springs.
    func displaced(_ rest: NSRect, in sidebar: NSView) -> NSRect {
        if let held = heldOffset { return rest.offsetBy(dx: heldBase.x + held.x, dy: heldBase.y + held.y) }
        if let dropped = droppedAt {
            droppedAt = nil
            settleX.start(at: dropped.x - rest.minX, toward: 0, in: sidebar)
            settleY.start(at: dropped.y - rest.minY, toward: 0, in: sidebar)
        }
        let dx = settleX.height(toward: 0, in: sidebar), dy = settleY.height(toward: 0, in: sidebar)
        return rest.offsetBy(dx: dx, dy: dy)
    }

    /// Tells the page where the card rests: its anchor, and the room from the card's top edge up to
    /// `area`'s top and from its bottom edge down to `area`'s bottom.
    func report(rest: NSRect, area: ClosedRange<CGFloat>) {
        island?.setPlace(SidebarCardPlace(anchor: anchor, above: max(0, rest.minY - area.lowerBound),
                                          below: max(0, area.upperBound - rest.maxY)))
    }
}
