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
    private var observation: Task<Void, Never>?

    init(strip: TabStripView) {
        self.strip = strip
        hover = HoverReveal(region: strip, tracksPointer: false)
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observation?.cancel()
        }
    }

    var isRevealed: Bool { hover.isRevealed }

    /// Adds the plus and follows `tabs.plusButton` live.
    func install() {
        guard strip != nil else { return }
        applyPlusButtonMode()
        // task-owner: this controller (cancelled in deinit); event-driven (Observation).
        observation = Task { [weak self] in
            for await _ in ObservationStream({
                (DesignSettings.shared.plusButton, TabTunables.restingControlOpacity.value, TabTunables.crowdedControls.value, TabTunables.crowdedControlOpacity.value)
            }) {
                self?.applyPlusButtonMode()
            }
        }
    }

    /// `tabs.plusButton`: hover brightens the muted plus and its pane-type chooser; always keeps both fully shown.
    func applyPlusButtonMode() {
        guard let strip else { return }
        // Hidden at rest while the tabs leave room; muted once they fill the bar, so its kept room never
        // reads as an empty gap (Leo 2026-10-19, 2026-10-20).
        hover.restAlpha = TabTunables.restingControlAlpha(crowded: strip.isCrowded)
        // The chooser sits beside the plus, so it fades with it; it never shows next to a hidden plus.
        for control in [strip.newTabButton, strip.newTabMenuButton] as [NSView] {
            if DesignSettings.shared.plusButton == .hover {
                if HoverReveal.owner(of: control) == nil { hover.add(control) }
            } else {
                hover.remove(control)
            }
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
