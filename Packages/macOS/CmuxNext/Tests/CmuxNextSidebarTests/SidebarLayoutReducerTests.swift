import Foundation
import Testing
@testable import CmuxNextSidebar

/// The section layout reducer (plans/cmux-next/sidebar-sections.md 4):
/// defaults, every op, invariants L1-L6, idempotency and the wire format.
@Suite struct SidebarLayoutReducerTests {
    private let defaults = SidebarLayoutDocument.defaults
    private let home = LayoutItemID("itm_home")
    private let settings = LayoutItemID("itm_settings")

    private func reduce(_ doc: SidebarLayoutDocument, _ op: SidebarLayoutOp) throws -> SidebarLayoutDocument {
        try SidebarLayoutReducer.reduce(doc, op).get()
    }

    private func reject(_ doc: SidebarLayoutDocument, _ op: SidebarLayoutOp) -> SidebarLayoutReject? {
        if case .failure(let reason) = SidebarLayoutReducer.reduce(doc, op) { return reason }
        return nil
    }

    // MARK: Defaults

    @Test func defaultsAreHomeWorkspacesSettingsCustomizeAccount() {
        #expect(defaults.sections(in: .top, room: nil).flatMap(\.items).map(\.ref) == [.app("cmux/home"), .app("cmux/app-store")])
        #expect(defaults.sections(in: .middle, room: nil).map(\.content) == [.workspaces])
        #expect(defaults.sections(in: .bottom, room: nil).flatMap(\.items).map(\.ref) == [.builtIn(.settings), .builtIn(.account)])
        #expect(defaults.sections.filter { $0.region != .middle && $0.content == .items }.allSatisfy { $0.look == .builtIn && $0.title == nil })
        #expect(defaults.sections.allSatisfy { $0.content != .app })
        #expect(defaults.firstTopItem(room: nil)?.ref == .app("cmux/home"))
    }

    // MARK: Items

    @Test func removeHomeMakesTheAppStoreTheFirstTopItem() throws {
        let doc = try reduce(defaults, .itemRemove(home))
        #expect(doc.firstItem(with: .app("cmux/home")) == nil)
        #expect(doc.firstTopItem(room: nil)?.ref == .app("cmux/app-store"))
        #expect(doc.revision == defaults.revision + 1)
    }

    @Test func addPinsAtIndexAndClampsTheIndex() throws {
        let ws = LayoutItem(id: LayoutItemID("itm_ws"), ref: .workspace("local:ws_1"))
        let doc = try reduce(defaults, .itemAdd(ws, section: SidebarLayoutDocument.topSectionID, index: 99))
        #expect(doc.section(SidebarLayoutDocument.topSectionID)?.items.map(\.id) == [home, LayoutItemID("itm_app_store"), ws.id])
        let front = try reduce(defaults, .itemAdd(ws, section: SidebarLayoutDocument.topSectionID, index: -3))
        #expect(front.section(SidebarLayoutDocument.topSectionID)?.items.first?.id == ws.id)
    }

    @Test func addingTheSameRefTwiceToASectionIsANoOp() throws {
        let again = LayoutItem(id: LayoutItemID("itm_home2"), ref: .app("cmux/home"))
        let doc = try reduce(defaults, .itemAdd(again, section: SidebarLayoutDocument.topSectionID, index: 0))
        #expect(doc == defaults)
    }

    @Test func theSameRefMayLiveInTwoSections() throws {
        let copy = LayoutItem(id: LayoutItemID("itm_home2"), ref: .app("cmux/home"))
        let doc = try reduce(defaults, .itemAdd(copy, section: SidebarLayoutDocument.bottomSectionID, index: 0))
        #expect(doc.section(SidebarLayoutDocument.bottomSectionID)?.items.first == copy)
    }

    @Test func itemsCannotGoIntoTheWorkspacesSection() {
        let item = LayoutItem(id: LayoutItemID("itm_x"), ref: .builtIn(.history))
        #expect(reject(defaults, .itemAdd(item, section: SidebarLayoutDocument.workspacesSectionID, index: 0)) == .workspacesRequired)
        #expect(reject(defaults, .itemMove(home, section: SidebarLayoutDocument.workspacesSectionID, index: 0)) == .workspacesRequired)
    }

    @Test func duplicateItemIDIsRefused() {
        let item = LayoutItem(id: settings, ref: .builtIn(.history))
        #expect(reject(defaults, .itemAdd(item, section: SidebarLayoutDocument.topSectionID, index: 0)) == .duplicateID)
    }

    @Test func moveAcrossRegionsKeepsTheItem() throws {
        let doc = try reduce(defaults, .itemMove(home, section: SidebarLayoutDocument.bottomSectionID, index: 1))
        #expect(doc.section(SidebarLayoutDocument.bottomSectionID)?.items.map(\.id) == [settings, home, LayoutItemID("itm_account")])
        #expect(doc.section(SidebarLayoutDocument.topSectionID)?.items.map(\.id) == [LayoutItemID("itm_app_store")])
        #expect(Set(Self.itemIDs(doc)) == Set(Self.itemIDs(defaults)))
    }

    @Test func moveWithinASectionExcludesItself() throws {
        let doc = try reduce(defaults, .itemMove(settings, section: SidebarLayoutDocument.bottomSectionID, index: 1))
        #expect(doc.section(SidebarLayoutDocument.bottomSectionID)?.items.map(\.id) == [LayoutItemID("itm_account"), settings])
    }

    @Test func moveOntoASectionHoldingTheSameRefIsRefused() throws {
        let copy = LayoutItem(id: LayoutItemID("itm_home2"), ref: .app("cmux/home"))
        let doc = try reduce(defaults, .itemAdd(copy, section: SidebarLayoutDocument.bottomSectionID, index: 0))
        #expect(reject(doc, .itemMove(home, section: SidebarLayoutDocument.bottomSectionID, index: 0)) == .duplicateRef)
    }

    @Test func moveToTheSamePlaceIsANoOp() throws {
        let doc = try reduce(defaults, .itemMove(home, section: SidebarLayoutDocument.topSectionID, index: 0))
        #expect(doc == defaults)
    }

    @Test func unknownTargetsAreRefused() {
        #expect(reject(defaults, .itemRemove(LayoutItemID("itm_nope"))) == .unknownItem)
        #expect(reject(defaults, .itemMove(home, section: LayoutSectionID("sec_nope"), index: 0)) == .unknownSection)
        #expect(reject(defaults, .sectionRemove(LayoutSectionID("sec_nope"))) == .unknownSection)
    }

    // MARK: Sections

    @Test func addSectionAtRegionIndex() throws {
        let section = LayoutSection(id: LayoutSectionID("sec_p"), title: "Project", region: .top, look: .list)
        let doc = try reduce(defaults, .sectionAdd(section, index: 0))
        #expect(doc.sections(in: .top, room: nil).map(\.id) == [section.id, SidebarLayoutDocument.topSectionID])
        let after = try reduce(defaults, .sectionAdd(section, index: 5))
        #expect(after.sections(in: .top, room: nil).map(\.id) == [SidebarLayoutDocument.topSectionID, section.id])
    }

    @Test func aSecondWorkspacesSectionIsRefused() {
        let section = LayoutSection(id: LayoutSectionID("sec_w2"), region: .top, content: .workspaces)
        #expect(reject(defaults, .sectionAdd(section, index: 0)) == .workspacesRequired)
    }

    @Test func removingTheWorkspacesSectionIsRefused() {
        #expect(reject(defaults, .sectionRemove(SidebarLayoutDocument.workspacesSectionID)) == .workspacesRequired)
    }

    @Test func removingASectionDeletesItsItems() throws {
        let doc = try reduce(defaults, .sectionRemove(SidebarLayoutDocument.bottomSectionID))
        #expect(doc.item(settings) == nil)
        #expect(doc.sections(in: .bottom, room: nil).isEmpty)
    }

    @Test func moveSectionBetweenRegions() throws {
        let doc = try reduce(defaults, .sectionMove(SidebarLayoutDocument.workspacesSectionID, region: .top, index: 1))
        #expect(doc.sections(in: .top, room: nil).map(\.id) == [SidebarLayoutDocument.topSectionID, SidebarLayoutDocument.workspacesSectionID])
        #expect(doc.sections(in: .middle, room: nil).isEmpty)
        let bottomFirst = try reduce(defaults, .sectionMove(SidebarLayoutDocument.topSectionID, region: .bottom, index: 0))
        #expect(bottomFirst.sections(in: .bottom, room: nil).map(\.id)
            == [SidebarLayoutDocument.topSectionID, SidebarLayoutDocument.bottomSectionID])
    }

    @Test func updateSetsAndClearsFields() throws {
        let id = SidebarLayoutDocument.bottomSectionID
        let set = try reduce(defaults, .sectionUpdate(id, SectionPatch(title: .set("Tools"), look: .list, room: .set("prof_a"), maxRows: .set(3))))
        let section = try #require(set.section(id))
        #expect(section.title == "Tools" && section.look == .list && section.room == "prof_a" && section.maxRows == 3)
        let cleared = try reduce(set, .sectionUpdate(id, SectionPatch(title: .clear, room: .clear, maxRows: .clear)))
        #expect(cleared.section(id)?.title == nil && cleared.section(id)?.room == nil && cleared.section(id)?.maxRows == nil)
        #expect(cleared.section(id)?.look == .list)
    }

    @Test func updateValidatesTitleAndMaxRows() {
        let id = SidebarLayoutDocument.bottomSectionID
        #expect(reject(defaults, .sectionUpdate(id, SectionPatch(title: .set("")))) == .invalidTitle)
        #expect(reject(defaults, .sectionUpdate(id, SectionPatch(title: .set(String(repeating: "x", count: 81))))) == .invalidTitle)
        #expect(reject(defaults, .sectionUpdate(id, SectionPatch(maxRows: .set(0)))) == .invalidMaxRows)
        #expect(reject(defaults, .sectionUpdate(id, SectionPatch(maxRows: .set(51)))) == .invalidMaxRows)
    }

    @Test func theWorkspacesSectionCannotBeRoomScoped() {
        let patch = SectionPatch(room: .set("prof_a"))
        #expect(reject(defaults, .sectionUpdate(SidebarLayoutDocument.workspacesSectionID, patch)) == .workspacesRequired)
    }

    @Test func resetOfTheDefaultsIsANoOp() throws {
        #expect(try reduce(defaults, .reset) == defaults)
    }

    @Test func showsTitleRoundTripsAndDefaultsToTrue() throws {
        let doc = try reduce(defaults, .sectionUpdate(SidebarLayoutDocument.bottomSectionID, SectionPatch(title: .set("Tools"), showsTitle: false)))
        #expect(doc.section(SidebarLayoutDocument.bottomSectionID)?.headerTitle == nil)
        let json = #"{"id":"sec_x","region":"top","look":"list","content":"items"}"#
        let section = try JSONDecoder().decode(LayoutSection.self, from: Data(json.utf8))
        #expect(section.showsTitle && section.items.isEmpty)
    }

    @Test func titlesCountUnicodeScalarsAndIDsAreUniqueAcrossSectionsAndItems() throws {
        let flags = String(repeating: "\u{1F1EF}\u{1F1F5}", count: 41) // 82 scalars, 41 graphemes
        #expect(reject(defaults, .sectionUpdate(SidebarLayoutDocument.bottomSectionID, SectionPatch(title: .set(flags)))) == .invalidTitle)
        let clash = LayoutSection(id: LayoutSectionID("itm_home"), region: .top)
        #expect(reject(defaults, .sectionAdd(clash, index: 0)) == .duplicateID)
        let item = LayoutItem(id: LayoutItemID("sec_bottom"), ref: .builtIn(.history))
        #expect(reject(defaults, .itemAdd(item, section: SidebarLayoutDocument.topSectionID, index: 0)) == .duplicateID)
    }

    @Test func appSectionsHoldNoItemsAndNameTheirApp() throws {
        let app = LayoutSection(id: LayoutSectionID("sec_app"), region: .top, content: .app, contribution: "manaflow-ai/github-prs#prs")
        let doc = try reduce(defaults, .sectionAdd(app, index: 9))
        #expect(doc.section(app.id)?.owningAppID == "manaflow-ai/github-prs")
        let item = LayoutItem(id: LayoutItemID("itm_x"), ref: .builtIn(.history))
        #expect(reject(doc, .itemAdd(item, section: app.id, index: 0)) == .itemsNotAllowed)
        #expect(reject(doc, .itemMove(home, section: app.id, index: 0)) == .itemsNotAllowed)
        #expect(LayoutItem(id: LayoutItemID("i"), ref: .app("a/b")).owningAppID == "a/b")
        #expect(defaults.section(SidebarLayoutDocument.topSectionID)?.owningAppID == nil)
    }

    @Test func removeRefTakesEveryCopyOutOfTheSidebar() throws {
        let copy = LayoutItem(id: LayoutItemID("itm_h2"), ref: .app("cmux/home"))
        let two = try reduce(defaults, .itemAdd(copy, section: SidebarLayoutDocument.bottomSectionID, index: 0))
        let none = try reduce(two, .itemRemoveRef(.app("cmux/home")))
        #expect(none.firstItem(with: .app("cmux/home")) == nil)
        #expect(none.revision == two.revision + 1)
        #expect(reject(none, .itemRemoveRef(.app("cmux/home"))) == .unknownItem)
    }

    @Test func itemUpdateTogglesTheLabel() throws {
        let doc = try reduce(defaults, .itemUpdate(LayoutItemID("itm_account"), showsLabel: true))
        #expect(doc.item(LayoutItemID("itm_account"))?.showsLabel == true)
        #expect(reject(defaults, .itemUpdate(LayoutItemID("itm_nope"), showsLabel: true)) == .unknownItem)
    }

    @Test func emptyPatchIsANoOp() throws {
        #expect(try reduce(defaults, .sectionUpdate(SidebarLayoutDocument.topSectionID, SectionPatch())) == defaults)
    }

    @Test func roomScopedSectionsShowOnlyInTheirRoom() throws {
        let section = LayoutSection(id: LayoutSectionID("sec_r"), title: "Project", region: .top, room: "prof_a")
        let doc = try reduce(defaults, .sectionAdd(section, index: 1))
        #expect(doc.sections(in: .top, room: "prof_a").map(\.id).contains(section.id))
        #expect(!doc.sections(in: .top, room: "prof_b").map(\.id).contains(section.id))
        #expect(!doc.sections(in: .top, room: nil).map(\.id).contains(section.id))
    }

    @Test func limits() throws {
        var doc = defaults
        for n in 0..<(SidebarLayoutReducer.maxSections - doc.sections.count) {
            doc = try reduce(doc, .sectionAdd(LayoutSection(id: LayoutSectionID("sec_\(n)"), region: .top), index: 0))
        }
        #expect(reject(doc, .sectionAdd(LayoutSection(id: LayoutSectionID("sec_over"), region: .top), index: 0)) == .tooMany)
    }

    @Test func resetRestoresDefaultsWithANewRevision() throws {
        let edited = try reduce(defaults, .itemRemove(home))
        let reset = try reduce(edited, .reset)
        #expect(reset.sections == defaults.sections)
        #expect(reset.revision == edited.revision + 1)
    }

    // MARK: Planner

    @Test func reAddHomeGoesBackToTheTop() throws {
        let removed = try reduce(defaults, .itemRemove(home))
        let op = try #require(SidebarLayoutPlanner.add(.app("cmux/home"), in: removed, newItem: LayoutItemID("itm_h2")))
        let doc = try reduce(removed, op)
        #expect(doc.firstTopItem(room: nil)?.ref == .app("cmux/home"))
        #expect(SidebarLayoutPlanner.add(.app("cmux/home"), in: defaults) == nil)
    }

    @Test func reAddHomeCreatesATopSectionWhenTheRegionIsEmpty() throws {
        let removed = try reduce(defaults, .sectionRemove(SidebarLayoutDocument.topSectionID))
        let op = try #require(SidebarLayoutPlanner.add(.app("cmux/home"), in: removed, newItem: LayoutItemID("itm_h2"),
                                                       newSection: LayoutSectionID("sec_t2")))
        let doc = try reduce(removed, op)
        let top = doc.sections(in: .top, room: nil)
        #expect(top.map(\.id) == [LayoutSectionID("sec_t2")])
        #expect(top.first?.look == .builtIn && top.first?.items.map(\.ref) == [.app("cmux/home")])
    }

    @Test func plannerRemove() throws {
        let op = try #require(SidebarLayoutPlanner.remove(.app("cmux/home"), in: defaults))
        #expect(op == .itemRemoveRef(.app("cmux/home")))
        #expect(SidebarLayoutPlanner.remove(.builtIn(.history), in: defaults) == nil)
    }

    // MARK: Idempotency

    @Test func replayingAKeyChangesNothing() {
        var owner = SidebarLayoutMemoryOwner()
        let first = owner.apply(.itemRemove(home), key: "k1")
        let replay = owner.apply(.itemRemove(home), key: "k1")
        #expect(first == replay)
        #expect(owner.document.revision == 1)
        #expect(owner.apply(.itemRemove(settings), key: "k1") == .failure(.idempotencyConflict))
        #expect(owner.document.item(settings) != nil)
        let label = SidebarLayoutOp.itemUpdate(LayoutItemID("itm_account"), showsLabel: true)
        #expect(owner.apply(label, key: "k2") == owner.apply(label, key: "k2"))
        #expect(owner.document.revision == 2)
    }

    // MARK: Wire

    @Test func opsRoundTripThroughJSON() throws {
        let ops: [SidebarLayoutOp] = [
            .sectionAdd(LayoutSection(id: LayoutSectionID("sec_a"), title: "A", region: .bottom, look: .builtIn, room: "prof_a", maxRows: 4,
                                      items: [LayoutItem(id: LayoutItemID("itm_a"), ref: .tab("local:tab_1"))]), index: 2),
            .sectionUpdate(LayoutSectionID("sec_a"), SectionPatch(title: .clear, look: .list, maxRows: .set(3))),
            .sectionMove(LayoutSectionID("sec_a"), region: .top, index: 0),
            .sectionRemove(LayoutSectionID("sec_a")),
            .itemAdd(LayoutItem(id: LayoutItemID("itm_b"), ref: .url("https://cmux.com")), section: LayoutSectionID("sec_top"), index: 1),
            .itemMove(LayoutItemID("itm_b"), section: LayoutSectionID("sec_bottom"), index: 0),
            .itemRemove(LayoutItemID("itm_b")),
            .itemUpdate(LayoutItemID("itm_account"), showsLabel: true),
            .itemRemoveRef(.app("manaflow-ai/github-prs")),
            .reset,
        ]
        for op in ops {
            let data = try JSONEncoder().encode(op)
            #expect(try JSONDecoder().decode(SidebarLayoutOp.self, from: data) == op)
        }
    }

    @Test func wireShapeIsSnakeCase() throws {
        let json = #"{"kind":"section.update","id":"sec_top","patch":{"title":null,"max_rows":5}}"#
        let op = try JSONDecoder().decode(SidebarLayoutOp.self, from: Data(json.utf8))
        #expect(op == .sectionUpdate(SidebarLayoutDocument.topSectionID, SectionPatch(title: .clear, maxRows: .set(5))))
        let doc = try JSONEncoder().encode(defaults)
        let text = String(decoding: doc, as: UTF8.self)
        #expect(text.contains(#""look":"built_in""#) && text.contains(#""content":"workspaces""#))
    }

    @Test func unknownRefKindsSurviveEdits() throws {
        let future = LayoutItem(id: LayoutItemID("itm_f"), ref: LayoutItemRef(kind: "hologram", value: "x"))
        var doc = try reduce(defaults, .itemAdd(future, section: SidebarLayoutDocument.topSectionID, index: 1))
        doc = try reduce(doc, .itemMove(home, section: SidebarLayoutDocument.bottomSectionID, index: 0))
        #expect(doc.item(future.id) == future)
        #expect(future.ref.builtIn == nil)
    }

    // MARK: Property test

    /// Random op sequences keep L1 (one workspaces section), L2 (unique
    /// ids; moves conserve items), L3 (one ref per section), L4 limits, and
    /// bump the revision by exactly one per change.
    @Test(arguments: [1, 7, 42, 1_234, 98_765])
    func randomOpsKeepInvariants(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        var doc = defaults
        for step in 0..<400 {
            let op = Self.randomOp(doc, step: step, rng: &rng)
            let before = doc
            guard case .success(let next) = SidebarLayoutReducer.reduce(doc, op) else { continue }
            doc = next
            #expect(doc.sections.filter { $0.content == .workspaces }.count == 1)
            let ids = Self.itemIDs(doc)
            #expect(ids.count == Set(ids).count)
            #expect(Set(doc.sections.map(\.id)).count == doc.sections.count)
            for section in doc.sections { #expect(Set(section.items.map(\.ref)).count == section.items.count) }
            #expect(doc.sections.count <= SidebarLayoutReducer.maxSections && ids.count <= SidebarLayoutReducer.maxItems)
            if case .itemMove = op { #expect(Set(ids) == Set(Self.itemIDs(before))) }
            if case .sectionMove = op { #expect(Set(ids) == Set(Self.itemIDs(before))) }
            #expect(doc.revision == before.revision + (doc.sections == before.sections ? 0 : 1))
            #expect(doc.sections.filter { $0.content == .workspaces }.allSatisfy { $0.room == nil })
            #expect(doc.sections.allSatisfy { $0.arrangement.isValid && ($0.maxRows.map(SidebarLayoutReducer.maxRowsRange.contains) ?? true) })
        }
    }

    static func itemIDs(_ doc: SidebarLayoutDocument) -> [LayoutItemID] { doc.sections.flatMap { $0.items.map(\.id) } }

    private static func randomOp(_ doc: SidebarLayoutDocument, step: Int, rng: inout SeededGenerator) -> SidebarLayoutOp {
        let sections = doc.sections.map(\.id) + [LayoutSectionID("sec_ghost")]
        let items = itemIDs(doc) + [LayoutItemID("itm_ghost")]
        let refs: [LayoutItemRef] = SidebarBuiltIn.allCases.map { .builtIn($0) } + [.workspace("local:ws_1"), .tab("local:tab_1")]
        let region = SidebarRegion.allCases.randomElement(using: &rng)!
        let index = Int.random(in: -1...4, using: &rng)
        switch Int.random(in: 0..<9, using: &rng) {
        case 0:
            let content: SectionContent = Int.random(in: 0..<10, using: &rng) == 0 ? .workspaces : .items
            return .sectionAdd(LayoutSection(id: LayoutSectionID("sec_r\(step)"), region: region, content: content), index: index)
        case 1:
            let layout = SectionArrangement.Layout.allCases.randomElement(using: &rng)!
            let align = SectionArrangement.Alignment.allCases.randomElement(using: &rng)!
            let patch = SectionPatch(title: .set("T\(step)"), maxRows: .set(Int.random(in: 0...52, using: &rng)),
                                     layout: layout, align: align, gap: .set(Int.random(in: -2...34, using: &rng)),
                                     columns: Bool.random(using: &rng) ? .clear : .set(Int.random(in: 0...14, using: &rng)))
            return .sectionUpdate(sections.randomElement(using: &rng)!, patch)
        case 2: return .sectionMove(sections.randomElement(using: &rng)!, region: region, index: index)
        case 3: return .sectionRemove(sections.randomElement(using: &rng)!)
        case 4, 5:
            return .itemAdd(LayoutItem(id: LayoutItemID("itm_r\(step)"), ref: refs.randomElement(using: &rng)!),
                            section: sections.randomElement(using: &rng)!, index: index)
        case 6: return .itemMove(items.randomElement(using: &rng)!, section: sections.randomElement(using: &rng)!, index: index)
        case 7:
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: return .itemRemove(items.randomElement(using: &rng)!)
            case 1: return .itemRemoveRef(refs.randomElement(using: &rng)!)
            default: return .itemUpdate(items.randomElement(using: &rng)!, showsLabel: Bool.random(using: &rng))
            }
        default: return Int.random(in: 0..<20, using: &rng) == 0 ? .reset : .itemMove(items.randomElement(using: &rng)!, section: sections.randomElement(using: &rng)!, index: index)
        }
    }
}

/// SplitMix64, so failures reproduce from the seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
