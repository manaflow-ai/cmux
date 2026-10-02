import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSettingsWindow
import CoreGraphics
import Foundation
import Testing

/// Search that jumps (plans/cmux-next/settings-ia.md rule 3): cards and
/// buttons are indexed, a key resolves to its section and anchor, the
/// `openSettings setting:` argument parses, the one page filters in place,
/// the scroll-spy follows header offsets, and the highlight honors Reduce
/// Motion.
@MainActor
@Suite struct SettingsJumpTests {
    /// A model on a scratch cmux.json with the whole action catalog, so the
    /// sections' buttons have titles.
    func makeModel() async throws -> SettingsWindowModel {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-settings-jump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}\n".utf8).write(to: url)
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        let settings = SettingsController(registry: registry, design: DesignSettings(), fileURL: url)
        settings.start()
        await settings.waitForLoad(atLeast: 1)
        return SettingsWindowModel(settings: settings, registry: registry, host: MockSettingsWindowHost())
    }

    // MARK: Index

    @Test func searchFindsCardsAndActionButtons() async throws {
        let model = try await makeModel()
        defer { model.settings.stop() }
        model.query = "theme"
        let theme = model.searchEntries()
        #expect(theme.contains { $0.kind == .card(.theme) && $0.anchor == .card(.theme) && $0.section == .appearance })

        model.query = "import from browser"
        let imports = model.searchEntries().filter { $0.kind == .action("importFromBrowser") }
        #expect(imports.map(\.anchor) == [.action("importFromBrowser", in: .browser)])

        model.query = "cmux.json"
        #expect(model.searchEntries().contains { $0.kind == .card(.advanced) })
        #expect(model.searchEntries().contains { $0.kind == .action("palette.openCmuxSettingsFile") })

        // Cards and buttons list after the section's rows, in their own card.
        model.query = "browser profiles"
        let sections = model.searchResultSections()
        let rooms = try #require(sections.first { $0.section == .rooms })
        #expect(rooms.others.contains { $0.kind == .card(.browserProfiles) })
        #expect(rooms.groups.allSatisfy { group in group.settings.allSatisfy { $0.section == .rooms } })
    }

    @Test func everyCardAndButtonIsIndexedOncePerPage() async throws {
        let model = try await makeModel()
        defer { model.settings.stop() }
        let entries = SettingsSearchIndex.entries(registry: model.registry)
        #expect(Set(entries.map(\.id)).count == entries.count, "anchor ids are unique across the one page")
        for card in SettingsCardID.allCases {
            #expect(entries.contains { $0.kind == .card(card) }, "\(card)")
        }
        for section in SettingsSection.allCases {
            for action in SettingsSchema.actions(in: section) {
                #expect(entries.contains { $0.anchor == .action(action, in: section) }, "\(section): \(action.rawValue)")
            }
        }
        // A button on two pages has an anchor on each.
        #expect(entries.contains { $0.anchor == .action("palette.openGhosttySettings", in: .appearance) })
        #expect(entries.contains { $0.anchor == .action("palette.openGhosttySettings", in: .terminal) })
    }

    // MARK: Jump target

    @Test func keysResolveToTheirSectionAndAnchor() {
        let speed = SettingsSearchIndex.anchor(for: "ui.animationSpeed")
        #expect(speed == SettingsAnchor(section: .appearance, id: "ui.animationSpeed"))
        #expect(SettingsSearchIndex.anchor(for: "  ui.animationSpeed\n") == speed)
        #expect(SettingsSearchIndex.anchor(for: "theme") == SettingsAnchor(section: .appearance, id: "card.theme"))
        #expect(SettingsSearchIndex.anchor(for: "card.machines") == SettingsAnchor(section: .machines, id: "card.machines"))
        #expect(SettingsSearchIndex.anchor(for: "importFromBrowser")
            == SettingsAnchor(section: .browser, id: "action.browser.importFromBrowser"))
        // A button on two pages: the bare id opens the first, the anchor id its own.
        #expect(SettingsSearchIndex.anchor(for: "palette.openGhosttySettings")?.section == .appearance)
        #expect(SettingsSearchIndex.anchor(for: "action.terminal.palette.openGhosttySettings")?.section == .terminal)
        let header = SettingsSearchIndex.anchor(for: "section.keyboard")
        #expect(header?.isHeader == true && header?.section == .keyboard)
        #expect(SettingsSearchIndex.anchor(for: "no.such.setting") == nil)
        #expect(SettingsSearchIndex.anchor(for: "   ") == nil)
    }

    @Test func openingAResultClearsTheQueryShowsItsPageAndHighlightsIt() async throws {
        let model = try await makeModel()
        defer { model.settings.stop() }
        model.query = "animations"
        #expect(model.openFirstResult())
        #expect(model.query.isEmpty)
        #expect(model.selection == .appearance)
        let first = try #require(model.jump)
        #expect(first.anchor.id == "ui.animationSpeed" && first.highlights)
        #expect(model.highlighted == "ui.animationSpeed")

        #expect(model.open(setting: "card.advanced"))
        let second = try #require(model.jump)
        #expect(second.serial > first.serial)
        #expect(model.selection == .advanced && model.highlighted == "card.advanced")
        // The first jump's highlight ending leaves the newer one lit.
        model.endHighlight(first)
        #expect(model.highlighted == "card.advanced")
        model.endHighlight(second)
        #expect(model.highlighted == nil)

        #expect(!model.open(setting: "no.such.setting"))
        #expect(model.jump == second)
        model.query = "zzzz-no-match"
        #expect(!model.openFirstResult())
    }

    @Test func aSidebarClickSelectsAPageOrScrollsTheOnePage() async throws {
        let model = try await makeModel()
        defer { model.settings.stop() }
        model.query = "font"
        model.select(.keyboard, layout: .pages)
        #expect(model.selection == .keyboard && model.query.isEmpty && model.jump == nil)

        model.query = "font"
        model.select(.notifications, layout: .onePage)
        let jump = try #require(model.jump)
        #expect(jump.anchor == .header(.notifications) && !jump.highlights)
        #expect(model.selection == .notifications && model.query.isEmpty && model.highlighted == nil)
    }

    // MARK: Deep link

    @Test func theSettingArgumentParses() throws {
        let link = SettingsDeepLink(ActionInvocation(arguments: ["section": .string("keyboard"), "setting": .string("  ui.animationSpeed ")]))
        #expect(link == SettingsDeepLink(section: .keyboard, setting: "ui.animationSpeed"))
        #expect(link.anchor == SettingsAnchor(section: .appearance, id: "ui.animationSpeed"))
        #expect(SettingsDeepLink(ActionInvocation()) == SettingsDeepLink())
        #expect(SettingsDeepLink(ActionInvocation(arguments: ["setting": .string("  ")])).setting == nil)
        #expect(SettingsDeepLink(ActionInvocation(arguments: ["section": .string("nope")])).section == nil)
        let unknown = SettingsDeepLink(ActionInvocation(arguments: ["setting": .string("no.such.setting")]))
        #expect(unknown.setting == "no.such.setting" && unknown.anchor == nil)

        // `cmux action run openSettings --arg setting=<key>` is optional text.
        let descriptor = try #require(ActionRegistry(catalog: ActionCatalog.all).descriptor(for: "openSettings"))
        let argument = try #require(descriptor.arguments.first { $0.name == "setting" })
        #expect(argument.kind == .string && !argument.isRequired)
        #expect(argument.parse("tabs.newTabKind") == .string("tabs.newTabKind"))
    }

    // MARK: One page

    @Test func theOnePageFilterHidesNonMatchingRowsEmptyGroupsAndSections() async throws {
        let model = try await makeModel()
        defer { model.settings.stop() }
        #expect(model.pageFilter() == nil)
        #expect(model.pageSections(nil) == SettingsSection.allCases)
        #expect(model.groups(in: .appearance).count > 1)

        model.query = "animations"
        let filter = try #require(model.pageFilter())
        #expect(filter.shows("ui.animationSpeed"))
        let groups = model.groups(in: .appearance, filter: filter)
        #expect(groups.count == 1)
        #expect(groups.flatMap(\.settings).map(\.id) == ["ui.animationSpeed"])
        #expect(model.groups(in: .general, filter: filter).isEmpty)
        #expect(model.actions(in: .appearance, filter: filter).isEmpty)
        #expect(!model.shows(.theme, filter: filter))
        // Keyboard stays when a shortcut matches ("Use Fast Animations").
        let sections = model.pageSections(filter)
        #expect(sections.contains(.appearance) && !sections.contains(.general) && !sections.contains(.rooms))

        // A matching card or button keeps its section; the rest stay hidden.
        model.query = "import from browser"
        let browser = try #require(model.pageFilter())
        #expect(model.actions(in: .browser, filter: browser) == ["importFromBrowser"])
        #expect(model.pageSections(browser).contains(.browser))
    }

    @Test func aFilterDropsGroupsLeftEmpty() throws {
        let descriptors = SettingsSchema.settings(in: .appearance)
        let kept = try #require(descriptors.first)
        let filter = SettingsPageFilter(matches: [SettingsSearchIndex.entry(for: kept)], shortcutsMatch: true)
        let groups = SettingsWindowModel.grouped(descriptors)
        #expect(filter.filter(groups).map(\.settings) == [[kept]])
        #expect(filter.filter(SettingsSection.allCases) == [.appearance, .keyboard])
    }

    // MARK: Scroll-spy

    @Test func theScrollSpyPicksTheLastHeaderPastTheLine() {
        let order: [SettingsSection] = [.general, .appearance, .terminal, .browser]
        let line: CGFloat = 30
        // Nothing measured yet, or the first header still below the line.
        #expect(SettingsScrollSpy.section(order: order, offsets: [:], line: line) == .general)
        #expect(SettingsScrollSpy.section(order: order, offsets: [.general: 40, .appearance: 400], line: line) == .general)
        // Scrolled: appearance's header passed the line, terminal's has not.
        let offsets: [SettingsSection: CGFloat] = [.general: -800, .appearance: -20, .terminal: 300, .browser: 900]
        #expect(SettingsScrollSpy.section(order: order, offsets: offsets, line: line) == .appearance)
        #expect(SettingsScrollSpy.section(order: order, offsets: offsets.merging([.terminal: 30]) { $1 }, line: line) == .terminal)
        // A hidden section (filtered out) is not in the order and never picked.
        #expect(SettingsScrollSpy.section(order: [.general, .terminal], offsets: offsets, line: line) == .general)
        #expect(SettingsScrollSpy.section(order: [], offsets: offsets, line: line) == nil)
    }

    // MARK: Highlight

    @Test func theHighlightFadesOrHoldsUnderReduceMotion() async throws {
        let length = MotionFade.highlight.baseDuration
        #expect(length == 1.2)
        let full = SettingsHighlightPlan.make(policy: MotionPolicy(speed: .fast, reduceMotion: false))
        #expect(full == SettingsHighlightPlan(hold: 0, fade: length))
        #expect(full.animates)
        let reduced = SettingsHighlightPlan.make(policy: MotionPolicy(speed: .fast, reduceMotion: true))
        #expect(reduced == SettingsHighlightPlan(hold: length, fade: 0))
        #expect(!reduced.animates)
        let off = SettingsHighlightPlan.make(policy: MotionPolicy(speed: .off, reduceMotion: false))
        #expect(off == SettingsHighlightPlan(hold: length, fade: 0))

        // The model's seam pins both states, whatever the test Mac has.
        let model = try await makeModel()
        defer { model.settings.stop() }
        model.motionPolicyOverride = MotionPolicy(speed: .fast, reduceMotion: true)
        #expect(model.highlightPlan == reduced)
        model.motionPolicyOverride = MotionPolicy(speed: .fast, reduceMotion: false)
        #expect(model.highlightPlan == full)
    }
}
