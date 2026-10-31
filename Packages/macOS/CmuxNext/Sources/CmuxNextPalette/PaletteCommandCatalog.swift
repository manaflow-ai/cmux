import CmuxNextActions
import Foundation
import Observation

/// The Commands palette's rows as a catalog for another surface (the New Tab page's dropdown): id, catalog title,
/// section, keywords and keycaps of every palette-visible row, built with no availability and no state, and kept
/// until a binding changes.
///
/// The New Tab page built the palette's full rows, availability included, for every Cmd-T (19 ms p50, up to 30 ms on
/// the main thread, fleet job 47430048563a3342afc8e209). A list that holds availability cannot be kept: a Cmd-T
/// changes the state the rows' closures read, so it would be built again every time (the first fix's head: 88 of 88
/// presses). This catalog reads only the registry's binding inputs, which a Cmd-T does not change, so it is built
/// once per binding change. A query's shown rows ask for their state (``PaletteController/commandStates(_:)``).
/// Chromium's omnibox works the same way: the provider data is an index built on change, and only a query's matches
/// are checked.
final class PaletteCommandCatalog {
    private var kept: (hidden: Set<ActionID>, entries: [PaletteCommandEntry])?
    /// Bumped by every drop: an observation armed before it marks nothing.
    private var generation = 0

    /// The kept catalog for `hidden`, else `build()`'s, kept until the registry's binding inputs change.
    func entries(_ registry: ActionRegistry, hidden: Set<ActionID>, _ build: () -> [PaletteCommandEntry]) -> [PaletteCommandEntry] {
        if let kept, kept.hidden == hidden { return kept.entries }
        generation += 1
        let armed = generation
        let entries = withObservationTracking {
            _ = registry.actions
            _ = registry.descriptors
            _ = registry.shortcutOverrides
            _ = registry.chordOverrides
            _ = registry.alternateShortcuts
            _ = registry.keyBindingLayers
            _ = registry.keyTierOverrides
            _ = registry.disabledFeatures
            return build()
        } onChange: { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.drop(armed) } // main-proof: checked on the line above
            } else {
                // task-owner: one hop for a write made off the main thread; the generation makes a late one a no-op
                Task { @MainActor [weak self] in self?.drop(armed) }
            }
        }
        kept = (hidden, entries)
        return entries
    }

    private func drop(_ armed: Int) {
        guard armed == generation else { return }
        kept = nil
    }
}
