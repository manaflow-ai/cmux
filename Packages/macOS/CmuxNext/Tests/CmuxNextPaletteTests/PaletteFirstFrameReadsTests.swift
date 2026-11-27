import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

/// Cmd-Shift-P reads, before its first frame, only the catalog actions its empty root can show (CMUX NEXT Stable perf
/// gate, 2026-11-27: on a bench build the open's model stage spent 25-36 ms of the key's turn reading the state of every
/// catalog action, hundreds of them, when the empty root lists its intents and family rows). Every other action is
/// read after the frame, once, and a query typed before that searches every action.
@MainActor
@Suite(.paletteRanker, .serialized, .closesItsWindows)
struct PaletteFirstFrameReadsTests {
    /// Each action whose palette title the open read (`Action.paletteTitle`: read once per action per read of its row).
    @MainActor final class Reads {
        var ids: [ActionID] = []
    }

    /// Every catalog action bound and available (the context has what each requires), each counting its reads.
    private static func registry(_ reads: Reads, context: ActionContext? = nil) -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for descriptor in registry.descriptors {
            if context == nil { registry.context.formUnion(descriptor.requires) }
            registry.bindEffect(descriptor.id) { _ in .done }
            guard var action = registry.action(for: descriptor.id) else { continue }
            let id = descriptor.id
            action.paletteTitle = {
                reads.ids.append(id)
                return nil
            }
            registry.register(action)
        }
        if let context { registry.context = context }
        return registry
    }

    private static func palette(_ registry: ActionRegistry) -> PaletteController {
        _ = NSApplication.shared
        let palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
        palette.prepare(step: 0)
        palette.prepare(step: 1)
        return palette
    }

    @Test func openReadsOnlyTheRootsActionsBeforeItsFirstFrame() async {
        let reads = Reads()
        let registry = Self.registry(reads)
        let palette = Self.palette(registry)
        defer { palette.closeForTest() }
        // What one full read of the commands reads: every action that can list here.
        reads.ids = []
        _ = RegistryPaletteProvider(registry: registry).makeItems()
        let expected = Set(reads.ids)
        reads.ids = []
        palette.show(.commands)
        let beforeFrame = reads.ids
        #expect(!palette.model.rows.isEmpty, "the first frame shows the root's rows")
        // The root lists its intents (about 130 actions) and 8 family rows, which need only the first rows of their
        // sections. Before this the open read every action that can list (hundreds) here.
        #expect(beforeFrame.count * 2 < expected.count,
                "the open read \(beforeFrame.count) of \(expected.count) actions before its first frame")
        await palette.model.settleDeferredLoads()
        // After the frame the rest are read, and none twice: the first frame's reads stand for this open.
        #expect(reads.ids.count == Set(reads.ids).count, "an action was read twice in one open")
        #expect(Set(reads.ids) == expected, "the open's reads differ from a full read's by \(Set(reads.ids).symmetricDifference(expected).count) actions")
    }

    /// The first frame's rows are the rows the full read lists for the empty root: the same visible rows, with the
    /// same titles, states and keycaps, in the same order, whatever the context makes available.
    @Test(arguments: [false, true])
    func firstFrameShowsWhatTheFullReadShows(sparseContext: Bool) throws {
        let reads = Reads()
        let registry = Self.registry(reads, context: sparseContext ? ActionContext() : nil)
        let palette = Self.palette(registry)
        defer { palette.closeForTest() }
        let provider = try #require(palette.commandsPage().providers.first as? RegistryPaletteProvider)
        let first = try #require(provider.firstFrameItems, "the root reads a first frame")
        let full = provider.makeItems()
        func shown(_ items: [PaletteItem]) -> [String] {
            items.filter { !$0.hidesWhenQueryEmpty }.map { "\($0.id)|\($0.title)|\($0.isEnabled)|\($0.keycaps ?? [])|\(String(describing: $0.toggleState))" }
        }
        #expect(!shown(first).isEmpty)
        #expect(shown(first) == shown(full))
    }

    /// A pinned action and an action the usage history knows are on the first frame (the empty query's Pinned and
    /// Recent rows), though the root does not list them.
    @Test func firstFrameHasThePinnedAndRecentActions() throws {
        let reads = Reads()
        let registry = Self.registry(reads)
        let palette = Self.palette(registry)
        defer { palette.closeForTest() }
        let roots = RegistryPaletteProvider.rootIntentIDs
        let others = registry.descriptors.map(\.id).filter { !roots.contains($0) && $0 != "commandPalette" }
        let full = RegistryPaletteProvider(registry: registry).makeItems()
        let listed = Set(full.compactMap(\.actionID))
        let candidates = others.filter { listed.contains($0) }
        let pinned = try #require(candidates.first), recent = try #require(candidates.dropFirst().first)
        palette.model.searcher.rankSettings.withLock { $0.pins = [pinned.rawValue] }
        palette.model.recordUse("action:\(recent.rawValue)")
        let provider = try #require(palette.commandsPage().providers.first as? RegistryPaletteProvider)
        let first = try #require(provider.firstFrameItems)
        let ids = Set(first.compactMap(\.actionID))
        #expect(ids.contains(pinned), "the pinned \(pinned) is not on the first frame")
        #expect(ids.contains(recent), "the recent \(recent) is not on the first frame")
    }

    /// A query typed before the first frame searches every action: the rows the open left for after the frame load
    /// before the search.
    @Test func queryTypedBeforeTheFrameFindsAnyAction() async throws {
        let reads = Reads()
        let registry = Self.registry(reads)
        let palette = Self.palette(registry)
        defer { palette.closeForTest() }
        let roots = RegistryPaletteProvider.rootIntentIDs
        // The root's own full read (its family rows included), as the open reads it after its frame.
        let full = try #require(palette.commandsPage().providers.first as? RegistryPaletteProvider).makeItems()
        let target = try #require(full.first { item in
            guard let id = item.actionID, !roots.contains(id), item.isEnabled else { return false }
            return registry.descriptor(for: id).map { !$0.title.isEmpty } ?? false
        })
        palette.show(.commands)
        palette.model.send(.setQuery(target.title))
        // The search read every action first (the rows the open left for after its frame).
        #expect(palette.model.current?.providerItems["registry"]?.count == full.count)
        await palette.model.settle()
        #expect(palette.model.rows.contains { $0.item.actionID == target.actionID }, "typing \"\(target.title)\" did not find it")
    }
}
