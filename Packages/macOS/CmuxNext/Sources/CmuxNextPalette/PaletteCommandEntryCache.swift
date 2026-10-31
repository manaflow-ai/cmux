import AppKit
import CmuxNextActions
import Foundation
import Observation

/// ``PaletteController/commandEntries()``'s rows, built once per change of what they read and kept per
/// focus context, so a surface that lists them (the New Tab page's dropdown, on every Cmd-T) takes a list
/// that was already built.
///
/// A build walks every catalog action through the palette's own provider. On the New Tab page it ran for
/// every Cmd-T, on the frame after the page showed. In the STRESS session Cmd-T took 83.5 ms p95 to its
/// committed frame, and its longest main-thread stall (131 ms) was this build (every-action sweep, fleet
/// job 59b1063a51893f653d11cfc6, feat 038bf00cc91, bench build).
///
/// A kept list must never offer a row that cannot run, so it is dropped on the first change of anything
/// its build read:
///
/// - the build runs under one observation: every `@Observable` property any row's title, state or
///   availability closure reads (the registry's bindings, catalog, shortcuts and features, and the app
///   state those closures read) drops every kept list on its first write;
/// - the registry's binding inputs are also read explicitly, so they are watched even when no row reads them;
/// - what changes too often to watch, or is not observable, is part of the key: the focus facts
///   (`ActionRegistry.context`, written on every focus move; the build decides the rows in the key's context
///   and never reads the live one, so focus that leaves a New Tab page and comes back builds nothing),
///   the rows the app hides, and the key window (Stop All Agents reads the front window).
///
/// A row whose availability reads state that is neither observable nor in the key would be stale: such a
/// source belongs in the key. Chromium keeps its omnibox providers' data the same way: an index rebuilt on
/// change, never per keystroke or per new tab.
final class PaletteCommandEntryCache {
    /// The most contexts kept: a person's surfaces see a few, and an old one is cheap to build again.
    static let keptContexts = 8

    private struct Key: Hashable {
        var context: ActionContext
        var hidden: Set<ActionID>
        var keyWindow: ObjectIdentifier?
    }

    private var lists: [Key: [PaletteCommandEntry]] = [:]
    private var order: [Key] = []
    /// Bumped by every drop: an observation armed before it marks nothing.
    private var generation = 0

    init() {}

    /// The kept rows for the registry's context, `hidden` and the key window, else `build(context)`'s, which are
    /// then kept. `build` decides the rows in the context it is given, never the registry's live one.
    func entries(_ registry: ActionRegistry, hidden: Set<ActionID>,
                 _ build: (ActionContext) -> [PaletteCommandEntry]) -> [PaletteCommandEntry] {
        let key = Key(context: registry.context, hidden: hidden, keyWindow: NSApp?.keyWindow.map(ObjectIdentifier.init))
        if let list = lists[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return list
        }
        let armed = generation
        let list = withObservationTracking {
            _ = registry.actions
            _ = registry.descriptors
            _ = registry.shortcutOverrides
            _ = registry.chordOverrides
            _ = registry.alternateShortcuts
            _ = registry.keyBindingLayers
            _ = registry.keyTierOverrides
            _ = registry.disabledFeatures
            return build(key.context)
        } onChange: { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.drop(armed) } // main-proof: checked on the line above
            } else {
                // task-owner: one hop for a write made off the main thread; the generation makes a late one a no-op
                Task { @MainActor [weak self] in self?.drop(armed) }
            }
        }
        // A list built after a drop belongs to the new generation; one observed before it was dropped with it.
        guard armed == generation else { return list }
        lists[key] = list
        order.append(key)
        if order.count > Self.keptContexts { lists[order.removeFirst()] = nil }
        return list
    }

    private func drop(_ armed: Int) {
        guard armed == generation else { return }
        generation += 1
        lists = [:]
        order = []
    }
}
