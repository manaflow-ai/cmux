import CmuxNextDesign
import QuartzCore

/// Where a tab's marks draw (Lawrence 2026-10-19: "There should only ever be a single unread
/// indicator for the right side", "nothing should ever be on the left side besides the favicon").
/// The leading slot draws only the favicon or the tab's icon. Every mark draws in one trailing
/// cluster at the end of the title, left of the x, in one order, left to right: the presence dot,
/// the profile dot, the machine badge, the theme swatch, the loading indicator, the speaker, then
/// the state slot at the far right. The unread dot and a status share one mark (`badgeColor`, or a
/// status icon set's glyph), so a tab never draws two.
///
/// The state slot is one fixed square, the spinner's size, and every state mark draws centered in
/// it (Leo 2026-10-22: "the tab unread + simultaneous ongoing thing feels I weird idk if there's a
/// way to combine + the spacing is off"). A busy tab without a status draws its spinner in that
/// slot, in place of the unread dot: an unread tab at work shows one mark, the spinner, and the dot
/// comes back in the same place when the work ends. Dots, glyphs and spinners line up across tabs.
/// A status (needs input, done, failed) keeps the slot; the spinner then draws left of the speaker.
/// `tabs.workingUnreadMark` (Debug Settings) holds the other looks tried.
///
/// A tab too narrow to show its title has no trailing room: there, as before, the loading
/// indicator takes the icon's place and the mark sits on the icon's corner (not beside a spinner).
extension TabCell {
    /// The trailing cluster, right to left (the order above, reversed).
    enum TrailingMark: CaseIterable {
        case state, audio, loading, theme, machine, profile, presence
    }

    /// Where a busy tab's spinner draws.
    enum SpinnerPlacement: Equatable {
        /// No spinner, or a status holds the state slot: the spinner (if any) draws left of the speaker.
        case beside
        /// In the state slot, in place of the unread dot.
        case inSlot
        /// In the state slot, around a smaller unread dot (`tabs.workingUnreadMark` ring).
        case aroundDot
        /// On the tab's icon, the unread dot in the state slot (`tabs.workingUnreadMark` icon).
        case onIcon
    }

    /// The spinner stands for the tab's state now: it shows, is not leaving, and no status holds the slot.
    var spinnerHoldsState: Bool {
        guard let spinnerLayer, !isSpinnerExiting, !spinnerLayer.layer.isHidden else { return false }
        return item.status == .none
    }

    /// Where the spinner draws on a tab that shows its title.
    var spinnerPlacement: SpinnerPlacement {
        guard spinnerHoldsState else { return .beside }
        guard item.isUnread else { return .inSlot }
        return switch metrics.workingUnreadMark {
        case .slot: .inSlot
        case .ring: .aroundDot
        case .icon: .onIcon
        }
    }

    /// The state slot's side: the trailing spinner's.
    var stateSlotSide: CGFloat { metrics.iconSize - 2 * Metrics.space1 }

    /// Lays the trailing cluster out from `titleEnd` leftward; returns where the title must end.
    /// The state mark and the loading indicator always draw (they say what the tab needs); the
    /// others draw while the title keeps a few characters, as each did alone.
    func layoutTrailingMarks(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat, onPath: Bool,
                             spinner placement: SpinnerPlacement) -> CGFloat {
        var end = titleEnd
        for mark in TrailingMark.allCases {
            switch mark {
            case .state: end = layoutStateSlot(end: end, midY: midY, onPath: onPath, spinner: placement)
            case .audio: end = layoutAudioBadge(titleX: titleX, titleEnd: end, midY: midY)
            case .loading: if placement == .beside { end = layoutTrailingSpinner(end: end, midY: midY) }
            case .theme: end = layoutThemeBadge(titleX: titleX, titleEnd: end, midY: midY)
            case .machine: end = layoutMachineBadge(titleX: titleX, titleEnd: end, midY: midY)
            case .profile: end = layoutProfileBadge(titleX: titleX, titleEnd: end, midY: midY)
            case .presence: end = layoutPresenceDot(titleX: titleX, titleEnd: end, midY: midY)
            }
        }
        return end
    }

    /// The state slot at the cluster's far right: the unread or status mark centered in it, or the
    /// spinner in its place (`placement`). Takes the slot's width and the gap before the next mark
    /// when anything draws there.
    private func layoutStateSlot(end: CGFloat, midY: CGFloat, onPath: Bool, spinner placement: SpinnerPlacement) -> CGFloat {
        let side = stateSlotSide
        let slot = CGRect(x: pixel(end - side), y: pixel(midY - side / 2), width: side, height: side)
        let dotSide = placement == .aroundDot ? max(Metrics.space1, metrics.badgeSize - Metrics.space1) : metrics.badgeSize
        var holds = false
        if placement == .inSlot || placement == .aroundDot, let spinnerLayer {
            spinnerLayer.layer.opacity = 1
            spinnerLayer.frame = slot
            holds = true
        }
        if placeStateMark(dot: centered(dotSide, in: slot), glyph: centered(pixel(metrics.iconSize * 0.62), in: slot),
                          visible: placement != .inSlot, onPath: onPath) != nil {
            holds = true
        }
        return holds ? end - side - Metrics.space2 : end
    }

    /// A square `side` wide centered in `slot`, on the pixel grid.
    private func centered(_ side: CGFloat, in slot: CGRect) -> CGRect {
        CGRect(x: pixel(slot.midX - side / 2), y: pixel(slot.midY - side / 2), width: side, height: side)
    }

    /// The loading indicator left of the speaker while a status holds the state slot.
    private func layoutTrailingSpinner(end: CGFloat, midY: CGFloat) -> CGFloat {
        guard let spinnerLayer else { return end }
        // A spinner fading out of the state slot stays there while the dot comes back under it.
        if isSpinnerExiting, item.status == .none { return end }
        if !isSpinnerExiting { spinnerLayer.layer.opacity = 1 }
        let side = stateSlotSide
        spinnerLayer.frame = CGRect(x: pixel(end - side), y: pixel(midY - side / 2), width: side, height: side)
        return end - side - Metrics.space2
    }

    /// The mark on the icon's top trailing corner, for a tab that shows no title. A spinner on the
    /// icon stands for the unread dot there too, so the corner stays empty while it turns.
    func layoutStateMark(iconFrame: CGRect, visible: Bool, onPath: Bool) {
        let visible = visible && !spinnerHoldsState
        let badge = metrics.badgeSize
        let dot = CGRect(x: pixel(iconFrame.maxX - badge + Metrics.space1), y: pixel(iconFrame.minY - Metrics.space1), width: badge, height: badge)
        let side = pixel(iconFrame.width * 0.62)
        let glyph = CGRect(x: pixel(iconFrame.maxX - side + Metrics.space1), y: pixel(iconFrame.minY - Metrics.space1), width: side, height: side)
        _ = placeStateMark(dot: dot, glyph: glyph, visible: visible, onPath: onPath)
    }

    /// Draws the one state mark: a status icon set's glyph at `glyph` when one draws, else the
    /// dot at `dot` while `badgeColor` says one shows. Returns the drawn mark's width, nil when none.
    private func placeStateMark(dot: CGRect, glyph: CGRect, visible: Bool, onPath: Bool) -> CGFloat? {
        if layoutStatusGlyph(frame: glyph, visible: visible) { removeBadge(onPath: onPath); return glyph.width }
        guard visible, badgeColor != nil else { removeBadge(onPath: onPath); return nil }
        let badgeLayer = makeBadge()
        badgeLayer.frame = dot
        badgeLayer.cornerRadius = dot.width / 2
        badgeLayer.opacity = 1
        return dot.width
    }

    private func removeBadge(onPath: Bool) {
        guard let badgeLayer else { return }
        if onPath {
            badgeLayer.opacity = 0
        } else {
            badgeLayer.removeFromSuperlayer()
            self.badgeLayer = nil
        }
    }
}
