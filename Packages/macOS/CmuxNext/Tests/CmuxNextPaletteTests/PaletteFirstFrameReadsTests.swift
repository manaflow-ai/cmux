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

    /// `pins`: the user's pinned actions, as cmux.json gives them (`PaletteSources.rankSettings`): each open reads them
    /// into the searcher again, so a pin written there directly is gone by the first frame.
    private static func palette(_ registry: ActionRegistry, pins: [ActionID] = []) -> PaletteController {
        _ = NSApplication.shared
        var sources = PaletteSources()
        sources.rankSettings = { PaletteRankSettings(pins: pins.map(\.rawValue)) }
        let palette = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
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
        // A full read of its own: the first frame's provider would take the first frame's reads as read.
        let full = try #require(palette.commandsPage().providers.first as? RegistryPaletteProvider).makeItems()
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
        let roots = RegistryPaletteProvider.rootIntentIDs
        let others = registry.descriptors.map(\.id).filter { !roots.contains($0) && $0 != "commandPalette" }
        let full = RegistryPaletteProvider(registry: registry).makeItems()
        let listed = Set(full.compactMap(\.actionID))
        let candidates = others.filter { listed.contains($0) }
        let pinned = try #require(candidates.first), recent = try #require(candidates.dropFirst().first)
        let palette = Self.palette(registry, pins: [pinned])
        defer { palette.closeForTest() }
        palette.configureScopes() // what each open does first: the pins into the searcher
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

    /// A family the usage history knows (a `family:` Recent row) is on the first frame with its members read.
    @Test func firstFrameHasARecentFamily() throws {
        let reads = Reads()
        let registry = Self.registry(reads)
        let palette = Self.palette(registry)
        defer { palette.closeForTest() }
        let full = try #require(palette.commandsPage().providers.first as? RegistryPaletteProvider).makeItems()
        let family = try #require(full.first { $0.id.hasPrefix("family:") && $0.isEnabled }, "the catalog lists a family row")
        palette.model.recordUse(family.id)
        let provider = try #require(palette.commandsPage().providers.first as? RegistryPaletteProvider)
        let first = try #require(provider.firstFrameItems)
        let row = try #require(first.first { $0.id == family.id }, "the recent \(family.id) is not on the first frame")
        #expect(row.isEnabled == family.isEnabled)
        #expect(row.section.id == family.section.id)
    }

    /// A long history reads only the uses the Recent section ranks from (the 15 strongest), not every row it knows:
    /// 300 used actions read no more than the root's own rows do, and the latest use is on the first frame.
    @Test func aLongHistoryReadsOnlyItsStrongestUses() async throws {
        let reads = Reads()
        let registry = Self.registry(reads)
        let palette = Self.palette(registry)
        defer { palette.closeForTest() }
        reads.ids = []
        _ = RegistryPaletteProvider(registry: registry).makeItems()
        let expected = Set(reads.ids)
        let roots = RegistryPaletteProvider.rootIntentIDs
        let used = registry.descriptors.map(\.id).filter { !roots.contains($0) && expected.contains($0) }.prefix(300)
        try #require(used.count > 2 * RegistryPaletteProvider.FirstFrameRows.recentCandidates)
        for id in used { palette.model.recordUse("action:\(id.rawValue)") }
        reads.ids = []
        palette.show(.commands)
        let beforeFrame = Set(reads.ids)
        #expect(beforeFrame.count * 2 < expected.count,
                "with \(used.count) uses the open read \(beforeFrame.count) of \(expected.count) actions before its first frame")
        let latest = try #require(used.last)
        #expect(beforeFrame.contains(latest), "the latest use \(latest) was not read for the first frame")
        await palette.model.settleDeferredLoads()
    }

    /// A toggle run before the open's after-frame load (type-ahead) lists its new state after the run: the run reads
    /// every action first, so the reload after it reads the toggle again, not the first frame's read.
    @Test func aToggleRunBeforeTheFrameListsItsNewState() async throws {
        let reads = Reads()
        let registry = Self.registry(reads)
        let roots = RegistryPaletteProvider.rootIntentIDs
        let full = RegistryPaletteProvider(registry: registry).makeItems()
        let listed = Set(full.compactMap(\.actionID))
        let id = try #require(registry.descriptors.first { descriptor in
            !roots.contains(descriptor.id) && listed.contains(descriptor.id) && descriptor.paletteTarget == nil
                && !descriptor.arguments.contains(where: \.palettePrompts)
        }?.id)
        @MainActor final class Setting { var on = false }
        let setting = Setting()
        registry.bindEffect(id) { _ in
            setting.on.toggle()
            return .done
        }
        var action = try #require(registry.action(for: id))
        action.paletteState = { setting.on }
        action.paletteStateIsSetting = true
        registry.register(action)
        let palette = Self.palette(registry, pins: [id])
        defer { palette.closeForTest() }
        palette.show(.commands)
        let shown = try #require(palette.model.current?.providerItems["registry"]?.first { $0.actionID == id },
                                 "the pinned toggle is not on the first frame")
        #expect(shown.toggleState == false)
        palette.model.run(shown.primary, of: shown)
        #expect(setting.on)
        let after = palette.model.current?.providerItems["registry"]?.first { $0.actionID == id }
        #expect(after?.toggleState == true, "the toggle lists its state before the run")
        await palette.model.settle()
    }

    /// A family row run before the open's after-frame load opens the family's page as a row run after it does: every
    /// member, folded as the root folds it.
    @Test func aFamilyRowRunBeforeTheFrameOpensItsWholePage() async throws {
        func page(runBeforeTheFrame: Bool) async throws -> (id: String, rows: [String]) {
            let reads = Reads()
            let palette = Self.palette(Self.registry(reads))
            defer { palette.closeForTest() }
            palette.show(.commands)
            if !runBeforeTheFrame { await palette.model.settle() }
            let row = try #require(palette.model.current?.providerItems["registry"]?.first { $0.id.hasPrefix("rootFamily:") && $0.isEnabled },
                                   "the root lists a family row")
            palette.model.run(row.primary, of: row)
            let items = try #require(palette.model.current?.providerItems[row.id], "the family row opened no page")
            await palette.model.settle()
            return (row.id, items.map { "\($0.id)|\($0.hidesWhenQueryEmpty)|\($0.isEnabled)|\(String(describing: $0.toggleState))" })
        }
        let early = try await page(runBeforeTheFrame: true)
        let late = try await page(runBeforeTheFrame: false)
        #expect(early.id == late.id)
        #expect(!early.rows.isEmpty)
        #expect(early.rows == late.rows, "a family page opened before the frame differs by \(Set(early.rows).symmetricDifference(late.rows).count) rows")
    }
}
