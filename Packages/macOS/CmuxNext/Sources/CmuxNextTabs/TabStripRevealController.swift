import AppKit
import CmuxNextDesign
import Observation

/// The strip's trailing buttons and its plus on the one hover-reveal
/// mechanism (R120): they fade in place while the strip is hovered, while a
/// strip menu is open or while VoiceOver focuses them (holds). The strip
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
    private var observation: Task<Void, Never>?

    init(strip: TabStripView) {
        self.strip = strip
        hover = HoverReveal(region: strip, tracksPointer: false)
    }

    isolated deinit {
        observation?.cancel()
    }

    var isRevealed: Bool { hover.isRevealed }

    /// Adds the views and follows `tabs.plusButton` live.
    func install() {
        guard let strip else { return }
        hover.add(strip.buttonGroup)
        applyPlusButtonMode()
        // task-owner: this controller (cancelled in deinit); event-driven (Observation).
        observation = Task { [weak self] in
            for await _ in Observations({ DesignSettings.shared.plusButton }) {
                self?.applyPlusButtonMode()
            }
        }
    }

    /// `tabs.plusButton`: hover reveals the plus with the trailing buttons;
    /// always keeps it shown.
    func applyPlusButtonMode() {
        guard let plus = strip?.newTabButton else { return }
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
