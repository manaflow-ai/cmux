import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Leo, 2026-11-07, on a palette with "VS Code Minimap" reading "Off" beside "Toggle Focus Ring"
/// drawing a switch: "Do we want to say off, or do we want to have the toggle? I'm almost leaning
/// towards off for this type of thing. ... I feel like if we're gonna do anything, we ought to, like,
/// just unify." Every row that flips a state, a Settings schema row and a catalog toggle alike, shows
/// "On" or "Off" the same way at its trailing edge, with no switch; Return flips a setting's row with
/// the palette open and the row reads its new state where it was.
@MainActor
@Suite(.serialized, .paletteRanker, .closesItsWindows)
struct PaletteSettingRowStateTests {
    private static let width: CGFloat = 640
    private static let height: CGFloat = 32

    @MainActor private final class Source: PaletteSettingsSource {
        var rows: [PaletteSettingRow] = [
            PaletteSettingRow(id: "agentPane.display.minimap", title: "Chat Minimap", group: "Agent Chat", value: "Off",
                              kind: .toggle(isOn: false)),
            PaletteSettingRow(id: "sound.effects", title: "Sound Effects", group: "Sound", value: "On", kind: .toggle(isOn: true)),
        ]
        func preview(row: String, option: String?) {}
        func commit(row: String, option: String) {}
        func commit(row: String, text: String) {}
    }

    /// A state a bound toggle reads and flips.
    @MainActor private final class Switch {
        var isOn: Bool
        init(_ isOn: Bool) { self.isOn = isOn }
    }

    private static func registry(_ focusRing: Switch, _ sidebar: Switch = Switch(true)) -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.bind("focusRing.toggle") { focusRing.isOn.toggle() }
        ActionTargetTitles.setPaletteSettingState("focusRing.toggle", in: registry) { focusRing.isOn }
        registry.bind("toggleSidebar") { sidebar.isOn.toggle() }
        ActionTargetTitles.setPaletteState("toggleSidebar", in: registry) { sidebar.isOn }
        return registry
    }

    /// The row drawn in a cell, and its pixels in the trailing fifth (where the state shows).
    private static func drawn(_ item: PaletteItem) throws -> (cell: PaletteRowCell, trailing: [UInt32]) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let cell = PaletteRowCell(frame: frame)
        window.contentView = cell
        cell.configure(PaletteRow(item: item, highlights: [], score: 0), isSelected: false)
        cell.layoutSubtreeIfNeeded()
        let rep = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: rep)
        var pixels: [UInt32] = []
        let start = Int(CGFloat(rep.pixelsWide) * 0.8)
        for y in 0..<rep.pixelsHigh {
            for x in start..<rep.pixelsWide {
                var p = [Int](repeating: 0, count: 4)
                rep.getPixel(&p, atX: x, y: y)
                pixels.append(UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3]))
            }
        }
        return (cell, pixels)
    }

    /// A preset with a state ("Density: Compact", marked while in use) is not an on/off setting: Return
    /// picks it and closes the palette, as before, while Focus Ring in the same Settings category still
    /// flips in place.
    @Test func aDensityPresetClosesThePaletteWhileFocusRingFlipsInPlace() async throws {
        _ = NSApplication.shared
        let focusRing = Switch(false)
        var density = "comfortable"
        let registry = Self.registry(focusRing)
        registry.bind("appearance.density.compact") { density = "compact" }
        ActionTargetTitles.setPaletteState("appearance.density.compact", in: registry) { density == "compact" }
        let palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }

        palette.show(.commands)
        palette.model.send(.setQuery("Focus Ring"))
        await palette.model.settle()
        let ring = try #require(palette.model.rows.first { $0.item.actionID == "focusRing.toggle" })
        palette.model.run(ring.item.primary, of: ring.item)
        await palette.model.settle()
        #expect(focusRing.isOn, "Focus Ring flipped")
        #expect(palette.visiblePanel != nil, "Focus Ring flips with the palette open")

        palette.model.send(.setQuery("Density: Compact"))
        await palette.model.settle()
        let compact = try #require(palette.model.rows.first { $0.item.actionID == "appearance.density.compact" },
                                   "Density: Compact is listed")
        palette.model.run(compact.item.primary, of: compact.item)
        await palette.model.settle()
        #expect(density == "compact", "the preset was applied")
        #expect(palette.visiblePanel == nil, "picking a preset closes the palette")
    }

    /// The command row and the Settings row show their state one way: the plain "On"/"Off" at the
    /// trailing edge, not a switch on one and the setting's value text on the other.
    @Test func aSettingRowAndACommandRowShowTheirStateTheSameWay() throws {
        #expect(PaletteTunables.toggleStyle.value == .stateWord, "the default state is the plain On/Off")
        #expect(PaletteToggleStyle.allCases.allSatisfy { !$0.rawValue.localizedCaseInsensitiveContains("switch") },
                "no style draws a switch")

        let settings = SettingsPaletteProvider(source: Source(), showsItemsForEmptyQuery: true).makeItems()
        let minimap = try #require(settings.first { $0.id == "setting:agentPane.display.minimap" })
        let sound = try #require(settings.first { $0.id == "setting:sound.effects" })
        #expect(minimap.toggleState == false && sound.toggleState == true)
        #expect(minimap.accessory == nil, "the setting's own value text is not drawn beside the state")

        let registry = Self.registry(Switch(false))
        let focusRing = try #require(RegistryPaletteProvider(registry: registry).makeItems().first { $0.actionID == "focusRing.toggle" })
        #expect(focusRing.toggleState == false)
        #expect(focusRing.keycaps == nil, "nothing else draws at the trailing edge of this row")

        let settingOff = try Self.drawn(minimap)
        let commandOff = try Self.drawn(focusRing)
        let settingOn = try Self.drawn(sound)
        #expect(settingOff.cell.toggleBadge.isHidden == false && commandOff.cell.toggleBadge.isHidden == false)
        #expect(settingOff.trailing == commandOff.trailing, "an off setting row and an off command row end the same way")
        #expect(settingOn.trailing != settingOff.trailing, "on and off read differently")
        #expect(settingOff.cell.accessibilityValue() as? String == PaletteStrings.off)
        #expect(settingOn.cell.accessibilityValue() as? String == PaletteStrings.on)
    }

    /// The state column is as wide as the wider word, so flipping a row never moves its title or keycaps.
    @Test func theStateColumnKeepsItsWidthWhenTheRowFlips() {
        let badge = PaletteToggleBadgeView()
        badge.style = .stateWord
        badge.isOn = true
        let on = badge.intrinsicContentSize
        badge.isOn = false
        #expect(badge.intrinsicContentSize == on)
        #expect(on.width > 0)
    }

    /// Return on a setting's command row (Focus Ring) flips it with the palette open, and the row reads
    /// its new state in place, still selected. An on/off command on what is in front (Left Sidebar)
    /// still runs and closes.
    @Test func returnFlipsASettingRowInPlace() async throws {
        _ = NSApplication.shared
        let focusRing = Switch(false)
        let palette = PaletteController(registry: Self.registry(focusRing), sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }
        palette.show(.commands)
        palette.model.send(.setQuery("Focus Ring"))
        await palette.model.settle()

        func row() -> PaletteRow? { palette.model.rows.first { $0.item.actionID == "focusRing.toggle" } }
        let before = try #require(row(), "Focus Ring is listed")
        #expect(before.item.toggleState == false)
        let index = palette.model.rows.firstIndex { $0.id == before.id }

        for expected in [true, false, true] {
            let shown = try #require(row())
            palette.model.select(rowID: shown.id)
            palette.model.run(shown.item.primary, of: shown.item)
            await palette.model.settle()
            #expect(focusRing.isOn == expected, "the action ran")
            #expect(palette.visiblePanel != nil, "the palette stays open")
            #expect(palette.model.query == "Focus Ring", "the query stays")
            let after = try #require(row(), "the row is still listed")
            #expect(after.item.toggleState == expected, "the row reads its new state")
            #expect(palette.model.rows.firstIndex { $0.id == after.id } == index, "the row stays where it was")
            #expect(palette.model.selectedRowID == after.id, "the row stays selected")
        }

        palette.model.send(.setQuery("Left Sidebar"))
        await palette.model.settle()
        let sidebar = try #require(palette.model.rows.first { $0.item.actionID == "toggleSidebar" })
        palette.model.run(sidebar.item.primary, of: sidebar.item)
        await palette.model.settle()
        #expect(palette.visiblePanel == nil, "a command on what is in front closes the palette")
    }

    /// The same on the family page that lists it (Pane Borders and Focus Ring…): the page's rows were
    /// built when the page opened, and the flipped row still reads its new state there.
    @Test func returnFlipsASettingRowInPlaceOnItsFamilyPage() async throws {
        _ = NSApplication.shared
        let focusRing = Switch(false)
        let palette = PaletteController(registry: Self.registry(focusRing), sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }
        palette.show(.commands)
        palette.model.send(.setQuery("Pane Borders and Focus Ring"))
        await palette.model.settle()
        let family = try #require(palette.model.rows.first { $0.item.id == "family:paneChrome" }, "the family row is listed")
        palette.model.run(family.item.primary, of: family.item)
        await palette.model.settle()
        func row() -> PaletteRow? { palette.model.rows.first { $0.item.actionID == "focusRing.toggle" } }
        #expect(try #require(row(), "Focus Ring is on the page").item.toggleState == false)
        for expected in [true, false] {
            let shown = try #require(row())
            palette.model.run(shown.item.primary, of: shown.item)
            await palette.model.settle()
            #expect(focusRing.isOn == expected)
            #expect(palette.visiblePanel != nil, "the palette stays open")
            #expect(row()?.item.toggleState == expected, "the row on the family page reads its new state")
        }
    }

    /// On a family page a style that puts the state in the title (`titleSuffix`) reads the new state
    /// after a flip too, not only the trailing word.
    @Test func aFamilyPageRowRestylesItsTitleWhenItFlips() async throws {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(PaletteTunables.all)
        try #require(TunableStore.shared.set(PaletteTunables.toggleStyle.key, PaletteToggleStyle.titleSuffix.tunableValue)
            == PaletteToggleStyle.titleSuffix.tunableValue)
        defer { _ = TunableStore.shared.set(PaletteTunables.toggleStyle.key, nil) }
        let focusRing = Switch(false)
        let registry = Self.registry(focusRing)
        let items = RegistryPaletteProvider(registry: registry).makeItems()
        let member = try #require(items.first { $0.actionID == "focusRing.toggle" })
        let page = StaticPaletteProvider(id: "family:paneChrome", items: [member])
        #expect(page.immediateItems?.first?.title == PaletteStrings.titleWithState("Focus Ring", PaletteStrings.off))
        focusRing.isOn = true
        #expect(page.immediateItems?.first?.title == PaletteStrings.titleWithState("Focus Ring", PaletteStrings.on))
        #expect(page.immediateItems?.first?.toggleState == true)
    }

    /// A row named by its setting is still found by the verb people type.
    @Test func aSettingRowIsFoundByToggle() async throws {
        _ = NSApplication.shared
        let palette = PaletteController(registry: Self.registry(Switch(true)), sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }
        palette.show(.commands)
        palette.model.send(.setQuery("toggle focus ring"))
        await palette.model.settle()
        #expect(palette.model.rows.contains { $0.item.actionID == "focusRing.toggle" })
    }
}
