import CmuxNextActions
import Foundation
import Observation

/// ``PaletteController/commandEntries()``'s rows, built once per change of the registry's bindings and
/// kept per focus context, so a surface that lists them (the New Tab page's dropdown, on every Cmd-T)
/// takes a list that was already built.
///
/// A build walks every catalog action through the palette's own provider. On the New Tab page it ran for
/// every Cmd-T, on the frame after the page showed: 19.1 ms p50, 28.7 ms p95, 51.3 ms max of main-thread
/// time per Cmd-T (fleet job 585b71fb06b5e033c183573c). The rows depend on:
///
/// - what is bound and how (the registry's actions, catalog, shortcuts, key bindings, key tiers, turned-off
///   features): an observation of those drops every kept list on its first write;
/// - the focus facts (`ActionRegistry.context`), which change on every focus move: a list is kept for each
///   context it was built in, so focus that leaves a New Tab page and comes back builds nothing;
/// - the rows the app hides (`hiddenActionIDs`), part of the key.
///
/// Chromium's omnibox keeps its providers' data the same way: an index rebuilt on change, never per
/// keystroke or per new tab. A row whose availability comes from state none of these is (a closure reading
/// the windows or the selected tab) can be one change old in a kept list; ``PaletteController/runCommand(_:relativeTo:)``
/// builds fresh rows and does not run a row that cannot run now.
public final class PaletteCommandEntryCache {
    /// The most contexts kept: a person's surfaces see a few, and an old one is cheap to build again.
    public static let keptContexts = 8

    private struct Key: Hashable {
        var context: ActionContext
        var hidden: Set<ActionID>
    }

    private var lists: [Key: [PaletteCommandEntry]] = [:]
    private var order: [Key] = []
    private var watching = false
    /// Bumped by every drop: an observation armed before it marks nothing.
    private var generation = 0
    /// Builds since this cache was made (the cache's tests read it).
    public private(set) var builds = 0

    public init() {}

    /// The kept rows for the registry's context and `hidden`, else `build()`'s, which are then kept.
    func entries(_ registry: ActionRegistry, hidden: Set<ActionID>, _ build: () -> [PaletteCommandEntry]) -> [PaletteCommandEntry] {
        if !watching { watch(registry) }
        let key = Key(context: registry.context, hidden: hidden)
        if let list = lists[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return list
        }
        builds += 1
        let list = build()
        lists[key] = list
        order.append(key)
        if order.count > Self.keptContexts { lists[order.removeFirst()] = nil }
        return list
    }

    /// Drops every kept list on the first write to what binds an action; the next read watches again.
    private func watch(_ registry: ActionRegistry) {
        watching = true
        let armed = generation
        withObservationTracking {
            _ = registry.actions
            _ = registry.descriptors
            _ = registry.shortcutOverrides
            _ = registry.chordOverrides
            _ = registry.alternateShortcuts
            _ = registry.keyBindingLayers
            _ = registry.keyTierOverrides
            _ = registry.disabledFeatures
        } onChange: { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.drop(armed) } // main-proof: checked on the line above
            } else {
                // task-owner: one hop for a write made off the main thread; the generation makes a late one a no-op
                Task { @MainActor [weak self] in self?.drop(armed) }
            }
        }
    }

    private func drop(_ armed: Int) {
        guard armed == generation else { return }
        generation += 1
        lists = [:]
        order = []
        watching = false
    }
}
