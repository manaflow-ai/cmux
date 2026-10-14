import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// The Settings scope (cx-9ce.20): every way in shows the same Settings page, titled as a page
/// (not "Toggle Setting", the action's argument step), and its rows follow each keystroke as soon
/// as that keystroke's search lands, with no fixed wait in between.
@MainActor
@Suite(.paletteRanker)
struct PaletteSettingsScopeTests {
    @MainActor private final class Source: PaletteSettingsSource {
        var rows: [PaletteSettingRow] = [
            PaletteSettingRow(id: "files.hidden", title: "Hidden Files", group: "Files", value: "Off", kind: .toggle(isOn: false)),
            PaletteSettingRow(id: "sound.effects", title: "Sound Effects", group: "Sound", value: "On", kind: .toggle(isOn: true)),
            PaletteSettingRow(id: "window.snap", title: "Snap Windows", group: "Windows", value: "Off", kind: .toggle(isOn: false)),
            PaletteSettingRow(id: "tabs.bar", title: "Tab Bar", group: "Tabs", value: "On", kind: .toggle(isOn: true)),
        ]
        func preview(row: String, option: String?) {}
        func commit(row: String, option: String) {}
        func commit(row: String, text: String) {}
    }

    private static func palette() -> PaletteController {
        _ = NSApplication.shared
        var sources = PaletteSources()
        sources.settings = Source()
        let registry = ActionRegistry.standard()
        // As in the App: the handler needs the setting, so a run without one asks for it.
        registry.bind("palette.toggleSetting", invoke: { _ in })
        let palette = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        palette.bindRegistryActions()
        return palette
    }

    private static func settingTitles(_ palette: PaletteController) -> [String] {
        palette.model.rows.filter { $0.item.id.hasPrefix("setting:") }.map(\.item.title)
    }

    /// The page on screen is the Settings page, listing the settings.
    private static func expectSettingsPage(_ palette: PaletteController, _ route: Comment) {
        #expect(!palette.model.isTextInput, route)
        #expect(palette.model.pageTitle == PaletteStrings.settingsTitle, route)
        #expect(palette.model.placeholder == PaletteStrings.settingsPlaceholder, route)
        #expect(palette.model.breadcrumbs == [PaletteStrings.settingsTitle], route)
        #expect(settingTitles(palette).count == 4, route)
    }

    /// A shortcut, menu, CLI or `palette.run` run of Toggle Setting without a setting opened the
    /// action's free-text argument step: titled "Toggle Setting", placeholder "Setting", one
    /// submit row whatever was typed. It opens the Settings page, as the palette row does.
    @Test func runningToggleSettingWithoutASettingOpensTheSettingsPage() async {
        let palette = Self.palette()
        defer { palette.hide() }

        #expect(palette.registry.perform("palette.toggleSetting", invocation: ActionInvocation()))
        await palette.model.settle()
        Self.expectSettingsPage(palette, "a run without a setting")

        // The palette row and the `,` prefix open the same page.
        palette.hide()
        palette.show(.commands)
        palette.model.send(.setQuery("Toggle Setting"))
        await palette.model.settle()
        let row = palette.model.rows.first { $0.item.actionID == "palette.toggleSetting" }
        #expect(row != nil)
        if let row { palette.model.run(row.item.primary, of: row.item) }
        await palette.model.settle()
        Self.expectSettingsPage(palette, "the Toggle Setting row")

        palette.hide()
        palette.show(.commands)
        palette.model.send(.setQuery(","))
        await palette.model.settle()
        Self.expectSettingsPage(palette, "the , prefix")
    }

    /// Each keystroke's rows are on screen once its search lands: nothing waits a fixed interval
    /// before ranking or showing them. The per-keystroke latency is printed as the timing probe.
    @Test func settingsRowsFollowEachKeystrokeWithoutAFixedWait() async {
        let palette = Self.palette()
        defer { palette.hide() }
        palette.show(.commands)
        palette.model.send(.setQuery(","))
        await palette.model.settle()

        let steps: [(query: String, first: String)] = [
            ("t", "Tab Bar"), ("ta", "Tab Bar"), ("tab", "Tab Bar"),
            ("s", ""), ("sn", "Snap Windows"), ("so", "Sound Effects"), ("h", "Hidden Files"), ("hid", "Hidden Files"),
        ]
        let clock = ContinuousClock()
        var latencies: [Duration] = []
        for step in steps {
            let started = clock.now
            palette.model.send(.setQuery(step.query))
            await palette.model.settle()
            latencies.append(clock.now - started)
            #expect(palette.model.query == step.query)
            if !step.first.isEmpty {
                #expect(Self.settingTitles(palette).first == step.first, "query \(step.query)")
            }
            #expect(!palette.model.isRanking, "query \(step.query)")
        }
        let millis = latencies.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000 }
        print("palette settings keystroke-to-rows ms: \(millis.map { String(format: "%.1f", $0) }.joined(separator: " "))")
        // A fixed debounce (the reported ~1.5 s) would show here; a rank on a test host takes milliseconds.
        #expect(latencies.allSatisfy { $0 < .seconds(1) }, "keystroke-to-rows ms: \(millis)")
    }
}
