import CmuxNextDesign
@testable import CmuxNextSettingsWindow
import Foundation
import Testing

/// The Debug Settings window's model over its own tunable store: search
/// across sections, the Changed list, edits, resets and exports.
@MainActor
@Suite struct DebugSettingsModelTests {
    static let motion = TunableSection(id: "m", title: "Motion", symbol: "waveform", order: 1)
    static let overlay = TunableSection(id: "o", title: "Drop Overlay", symbol: "square.dashed", order: 0)
    let opacity = Tunable<Double>.number("drop.overlay.opacity", overlay, "Opacity", help: "Overlay alpha.", default: 1,
                                         range: 0.1...1, step: 0.05, unit: .fraction)
    let label = Tunable<Bool>.toggle("drop.overlay.showLabel", overlay, "Label", help: "Show the drop label.", default: true)
    let hover = Tunable<Double>.number("motion.fade.hover", motion, "hover fade", help: "Hover fills.", default: 0.08,
                                       range: 0...1, step: 0.01, unit: .seconds)

    func model() -> DebugSettingsModel {
        let store = TunableStore()
        let descriptors = [hover.descriptor, opacity.descriptor, label.descriptor]
        store.register(descriptors)
        store.activate(file: nil)
        return DebugSettingsModel(store: store, descriptors: descriptors)
    }

    @Test func listsSectionsInOrderAndSearchesAcrossThem() {
        let model = model()
        #expect(model.sections.map(\.id) == ["o", "m"])
        #expect(model.visible.count == 3)
        model.selection = .section("m")
        #expect(model.visible.map(\.key) == ["motion.fade.hover"])
        // A search ignores the selected section.
        model.query = "label"
        #expect(model.visible.map(\.key) == ["drop.overlay.showLabel"])
        model.query = "overlay"
        #expect(model.groupedVisible.map(\.section.id) == ["o"])
        model.query = "nothing like this"
        #expect(model.visible.isEmpty)
    }

    @Test func editsShowAsChangedAndSettingTheDefaultClearsTheOverride() {
        let model = model()
        model.set(opacity.descriptor, .number(0.5))
        #expect(model.isChanged(opacity.descriptor))
        #expect(model.changedCount == 1)
        model.selection = .changed
        #expect(model.visible.map(\.key) == ["drop.overlay.opacity"])
        model.set(opacity.descriptor, .number(1))
        #expect(!model.isChanged(opacity.descriptor))
        #expect(model.store.overrides.isEmpty)
        model.set(opacity.descriptor, .number(7))
        #expect(model.value(opacity.descriptor) == .number(1))
        #expect(!model.isChanged(opacity.descriptor))
    }

    @Test func resetsASectionOrEverything() {
        let model = model()
        model.set(opacity.descriptor, .number(0.4))
        model.set(label.descriptor, .bool(false))
        model.set(hover.descriptor, .number(0.2))
        model.reset(section: Self.overlay)
        #expect(model.changedCount == 1)
        model.resetAll()
        #expect(model.changedCount == 0)
        #expect(model.notice != nil)
    }

    @Test func exportsTheChangedValues() {
        let model = model()
        #expect(model.copyJSON(to: nil) == "{\n\n}" || model.copyJSON(to: nil) == "{}")
        model.set(hover.descriptor, .number(0.06))
        let json = model.copyJSON(to: nil)
        #expect(json.contains("\"motion.fade.hover\" : 0.06"))
        let swift = model.copySwift(to: nil)
        #expect(swift.contains("motion.fade.hover: 0.06"))
        #expect(swift.contains("was 0.08"))
    }
}
