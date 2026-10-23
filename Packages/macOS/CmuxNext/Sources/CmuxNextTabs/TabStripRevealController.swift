import AppKit
import CmuxNextCompat
import CmuxNextDesign
import Observation

/// The strip's plus on the one hover-reveal mechanism (R120): it brightens from
/// muted (`tabs.restingControlOpacity`) in place while the strip is hovered, while a strip menu is open or while
/// VoiceOver focuses the strip (holds). The strip
/// tracks the pointer itself and reports it (`TabStripButtonReveal`), so the
/// HoverReveal does not track it. `tabs.plusButton` = always keeps the plus
/// out of the reveal.
@MainActor
final class TabStripRevealController {
    private weak var strip: TabStripView?
    /// The reveal on the strip; created with the controller, so it never
    /// outlives the strip it fades.
    let hover: HoverReveal
    private var hold: HoverReveal.Hold?
    private var observation: OwnedTask?

    init(strip: TabStripView) {
        self.strip = strip
        hover = HoverReveal(region: strip, tracksPointer: false)
    }

    var isRevealed: Bool { hover.isRevealed }

    /// Adds the plus and follows `tabs.plusButton` live.
    func install() {
        guard strip != nil else { return }
        applyPlusButtonMode()
        // task-owner: this controller (released with it, which cancels it); event-driven (Observation).
        observation = OwnedTask(Task { [weak self] in
            for await _ in ObservationStream({ (DesignSettings.shared.plusButton, TabTunables.restingControlOpacity.value) }) {
                self?.applyPlusButtonMode()
            }
        })
    }

    /// `tabs.plusButton`: hover brightens the muted plus; always keeps it fully shown.
    func applyPlusButtonMode() {
        guard let plus = strip?.newTabButton else { return }
        // At rest the plus shows muted, so its kept room never reads as an empty gap (Leo 2026-10-19).
        hover.restAlpha = TabTunables.restingControlOpacity.value
        if DesignSettings.shared.plusButton == .hover {
            if HoverReveal.owner(of: plus) == nil { hover.add(plus) }
        } else {
            hover.remove(plus)
        }
    }

    /// Maps the strip's inputs onto the reveal: the pointer, and a hold for
    /// an open strip menu or VoiceOver focus.
    func sync(_ state: TabStripButtonReveal, from old: TabStripButtonReveal) {
        if state.pointerInStrip != old.pointerInStrip { hover.setPointerInside(state.pointerInStrip) }
        let holds = state.menuOpen || state.accessibilityFocused
        if holds, hold == nil {
            hold = hover.hold()
        } else if !holds, let current = hold {
            hold = nil
            current.release()
        }
    }
}
