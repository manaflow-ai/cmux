import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// The palette asks three rules of an action while it builds its rows: why the row cannot run for
/// the focused object, whether its toggle is on, and its title there. Each answers a QUESTION, so
/// a rule's lookup of an object that is gone refuses nothing: nobody ran an action. (The rules a
/// right-click menu and a run ask: `ActionQuestionRulesNeverRefuseTests`.)
@MainActor
struct PaletteQuestionRulesNeverRefuseTests {
    static let gone = "That tab is no longer open."
    static let id: ActionID = "agentPane.toggleFiles"

    /// A registry with `id` bound, what its observer heard and how often a rule's lookup missed.
    @MainActor
    private final class Fixture {
        let registry = ActionRegistry.standard()
        var heard: [String] = []
        var asked = 0

        init() {
            registry.context = ActionContext(rawValue: .max)
            registry.bind(PaletteQuestionRulesNeverRefuseTests.id) {}
            registry.refusalObserver = { [unowned self] reason, _ in self.heard.append(reason) }
        }

        /// A rule's lookup that misses: it refuses as the App's lookup of a target does.
        func miss() {
            asked += 1
            registry.refuseNotFound(PaletteQuestionRulesNeverRefuseTests.gone)
        }

        /// The palette's row of `id`, and what a capturing caller of the build got.
        func row() -> (item: PaletteItem?, captured: String?) {
            var item: PaletteItem?
            let captured = registry.capturingRefusal {
                item = RegistryPaletteProvider(registry: registry).makeItems().first {
                    $0.actionID == PaletteQuestionRulesNeverRefuseTests.id
                }
            }
            return (item, captured)
        }

        /// The row is listed, its rule was asked, and nobody heard a refusal.
        func expectAQuietRow(_ kind: Comment) {
            let built = row()
            #expect(built.item != nil, kind)
            #expect(asked > 0, kind)
            #expect(heard.isEmpty, kind)
            #expect(built.captured == nil, kind)
        }
    }

    /// Kind 6, `ActionTargetTitles.setPaletteReason`.
    @Test func aPaletteReasonRuleWhoseLookupMissesRefusesNothing() {
        let fixture = Fixture()
        ActionTargetTitles.setPaletteReason(Self.id, in: fixture.registry) { [unowned fixture] in fixture.miss(); return nil }
        fixture.expectAQuietRow("the palette's reason rule")
    }

    /// Kind 7, `ActionTargetTitles.setPaletteState` and `setPaletteSettingState`.
    @Test func aPaletteStateRuleWhoseLookupMissesRefusesNothing() {
        let plain = Fixture()
        ActionTargetTitles.setPaletteState(Self.id, in: plain.registry) { [unowned plain] in plain.miss(); return true }
        plain.expectAQuietRow("the palette's toggle state rule")
        let setting = Fixture()
        ActionTargetTitles.setPaletteSettingState(Self.id, in: setting.registry) { [unowned setting] in setting.miss(); return true }
        setting.expectAQuietRow("the palette's setting state rule")
    }

    /// Kind 8, `ActionTargetTitles.setPaletteTitle`.
    @Test func aPaletteTitleRuleWhoseLookupMissesRefusesNothing() {
        let fixture = Fixture()
        ActionTargetTitles.setPaletteTitle(Self.id, in: fixture.registry) { [unowned fixture] in fixture.miss(); return "Hide Files Beside Chat" }
        fixture.expectAQuietRow("the palette's title rule")
    }
}
