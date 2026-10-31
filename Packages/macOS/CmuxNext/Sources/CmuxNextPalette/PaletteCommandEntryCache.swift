import AppKit
import CmuxNextActions
import Foundation
import Observation
import os

/// ``PaletteController/commandEntries()``'s rows, built once per change of what they read and kept per
/// focus context, so a surface that lists them (the New Tab page's dropdown, on every Cmd-T) takes a list
/// that was already built.
///
/// A build walks every catalog action through the palette's own provider. On the New Tab page it ran for
/// every Cmd-T, on the frame after the page showed: 19.1 ms p50, 28.7 ms p95, 51.3 ms max of main-thread
/// time per Cmd-T (fleet job 585b71fb06b5e033c183573c).
///
/// A kept list must never offer a row that cannot run, so it is dropped on the first change of anything
/// its build read:
///
/// - the build runs under one observation: every `@Observable` property any row's title, state or
///   availability closure reads (the registry's bindings, catalog, shortcuts and features, and the app
///   state those closures read) drops every kept list on its first write;
/// - the registry's binding inputs are also read explicitly, so they are watched even when no row reads them;
/// - what is not observable is part of the key: the focus facts (`ActionRegistry.context`, which change on
///   every focus move, so a list is kept per context and focus that leaves and comes back builds nothing),
///   the rows the app hides, and the key window (Stop All Agents reads the front window).
///
/// A row whose availability reads state that is neither observable nor in the key would be stale. With
/// `CMUX_NEXT_PALETTE_ENTRY_CHECK=1` in the app's environment (DEBUG and bench builds; a bench
/// or dogfood run sets it), every kept list is compared with a fresh build: a difference is logged as
/// `palette.entries` "stale kept list" with the rows, counted (`staleHits`), and the fresh rows are returned.
/// Chromium keeps its omnibox providers' data the same way: an index rebuilt on change, never per keystroke or
/// per new tab.
public final class PaletteCommandEntryCache {
    /// The most contexts kept: a person's surfaces see a few, and an old one is cheap to build again.
    public static let keptContexts = 8
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "palette.entries")

    private struct Key: Hashable {
        var context: ActionContext
        var hidden: Set<ActionID>
        var keyWindow: ObjectIdentifier?
    }

    private var lists: [Key: [PaletteCommandEntry]] = [:]
    private var order: [Key] = []
    /// Bumped by every drop: an observation armed before it marks nothing.
    private var generation = 0
    /// Builds since this cache was made (the cache's tests read it).
    public private(set) var builds = 0
    /// Kept lists that differed from a fresh build (``verifiesHits``; the cache's tests read it).
    public private(set) var staleHits = 0
    /// Whether every kept list is compared with a fresh build (`CMUX_NEXT_PALETTE_ENTRY_CHECK=1`, DEBUG and
    /// bench builds only): the check costs the build it saves, so it is a diagnostic, never the default.
    public var verifiesHits: Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG || CMUX_BENCH_HOOKS
        verifiesHits = environment["CMUX_NEXT_PALETTE_ENTRY_CHECK"] == "1"
        #else
        verifiesHits = false
        #endif
    }

    /// The kept rows for the registry's context, `hidden` and the key window, else `build()`'s, which are then kept.
    func entries(_ registry: ActionRegistry, hidden: Set<ActionID>, _ build: () -> [PaletteCommandEntry]) -> [PaletteCommandEntry] {
        let key = Key(context: registry.context, hidden: hidden, keyWindow: NSApp?.keyWindow.map(ObjectIdentifier.init))
        if let list = lists[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return verifiesHits ? checked(list, build) : list
        }
        builds += 1
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
            return build()
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

    /// ``verifiesHits``: a kept list must equal a fresh build; a difference is a row whose availability reads
    /// state the cache neither watches nor keys on (logged with the rows, counted, and the fresh rows returned).
    private func checked(_ kept: [PaletteCommandEntry], _ build: () -> [PaletteCommandEntry]) -> [PaletteCommandEntry] {
        let fresh = build()
        guard fresh != kept else { return kept }
        staleHits += 1
        let keptIDs = Set(kept.map(\.id)), freshIDs = Set(fresh.map(\.id))
        let offered = keptIDs.subtracting(freshIDs).map(\.rawValue).sorted().joined(separator: ",")
        let missing = freshIDs.subtracting(keptIDs).map(\.rawValue).sorted().joined(separator: ",")
        Self.logger.fault("stale kept list: kept but not runnable [\(offered, privacy: .public)], runnable but not kept [\(missing, privacy: .public)]")
        return fresh
    }

    private func drop(_ armed: Int) {
        guard armed == generation else { return }
        generation += 1
        lists = [:]
        order = []
    }
}
