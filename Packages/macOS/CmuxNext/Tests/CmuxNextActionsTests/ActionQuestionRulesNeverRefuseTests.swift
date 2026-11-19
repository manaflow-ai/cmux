import AppKit
@testable import CmuxNextActions
import Testing

/// A rule that answers a QUESTION about an action (is its row left out for this target, why it
/// cannot run here, its title, its check mark, its chosen value) refuses nothing: only a run
/// refuses. A rule's lookup of a target that is gone (a tab the tree no longer has) told the
/// refusal observer "That tab is no longer open." while a right-click menu was built and no action
/// ran, and a caller's run got the lookup's words in place of the rule's own reason.
@MainActor
struct ActionQuestionRulesNeverRefuseTests {
    static let gone = "That tab is no longer open."
    static let why = "There are no other tabs to close."
    /// The action whose row the tab's right-click menu shows.
    static let row: ActionID = "closeOtherTabsInPane"
    /// The action the run rows run (it needs no context and no argument).
    static let run: ActionID = "minimizeWindow"
    static let target = ActionTargetRef(kind: .tab, id: "gone")

    /// A registry with both actions bound, what its observer heard, how often a rule's lookup
    /// missed and how often `run` ran.
    @MainActor
    private final class Fixture {
        let registry = ActionRegistry.standard()
        var heard: [String] = []
        var asked = 0
        var runs = 0
        /// What `run`'s handler does after it counts the run.
        var onRun: (@MainActor () -> Void)?

        init() {
            registry.bind(ActionQuestionRulesNeverRefuseTests.row, invoke: { _ in })
            registry.bind(ActionQuestionRulesNeverRefuseTests.run, invoke: { [unowned self] _ in
                self.runs += 1
                self.onRun?()
            })
            registry.refusalObserver = { [unowned self] reason, _ in self.heard.append(reason) }
        }

        /// A rule's lookup that misses: it refuses as the App's lookup of a target does.
        func miss() {
            asked += 1
            registry.refuseNotFound(ActionQuestionRulesNeverRefuseTests.gone)
        }

        /// The row of `row` in the tab's right-click menu, and what a capturing caller of the build got.
        func menuRow() -> (item: NSMenuItem?, captured: String?) {
            var item: NSMenuItem?
            let captured = registry.capturingRefusal {
                let menu = registry.makeContextMenu(for: .tab, target: ActionQuestionRulesNeverRefuseTests.target)
                item = Self.rows(menu).first { $0.identifier?.rawValue == "cmux.action.closeOtherTabsInPane" }
            }
            return (item, captured)
        }

        private static func rows(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(rows) ?? []) }
        }
    }

    /// Kind 1, `ActionTargetVisibility.hide`: the row is left out, and nobody hears a refusal.
    @Test func aHideRuleWhoseLookupMissesRefusesNothing() {
        let fixture = Fixture()
        ActionTargetVisibility.hide(Self.row, in: fixture.registry) { [unowned fixture] _ in fixture.miss(); return true }
        let built = fixture.menuRow()
        #expect(fixture.asked > 0, "the menu did not ask the hide rule")
        #expect(built.item == nil, "the rule's answer was lost: the row is in the menu")
        #expect(fixture.heard.isEmpty, "a menu build refused: \(fixture.heard)")
        #expect(built.captured == nil, "a menu build gave its caller a refusal")
    }

    /// Kind 2, `ActionTargetReasons.set`: the row and `reason(for:)` say the rule's reason, and nobody hears a refusal.
    @Test func aReasonRuleWhoseLookupMissesRefusesNothingWhenAsked() throws {
        let fixture = Fixture()
        for id in [Self.row, Self.run] {
            ActionTargetReasons.set(id, in: fixture.registry) { [unowned fixture] _ in fixture.miss(); return Self.why }
        }
        let built = fixture.menuRow()
        let item = try #require(built.item, "the row is not in the menu")
        #expect(item.toolTip == Self.why)
        let invocation = ActionInvocation(target: Self.target)
        #expect(ActionTargetReasons.reason(for: Self.run, invocation: invocation, in: fixture.registry) == Self.why)
        #expect(fixture.asked >= 2, "the menu and the reason read did not ask the rule")
        #expect(fixture.heard.isEmpty, "a question refused: \(fixture.heard)")
        #expect(built.captured == nil, "a menu build gave its caller a refusal")
    }

    /// Kind 3, `ActionTargetTitles.set`: the row has the rule's title, and nobody hears a refusal.
    @Test func aTitleRuleWhoseLookupMissesRefusesNothing() throws {
        let fixture = Fixture()
        ActionTargetTitles.set(Self.row, in: fixture.registry) { [unowned fixture] _ in fixture.miss(); return "Close the Others" }
        let built = fixture.menuRow()
        let item = try #require(built.item, "the row is not in the menu")
        #expect(item.title == "Close the Others")
        #expect(fixture.asked > 0, "the menu did not ask the title rule")
        #expect(fixture.heard.isEmpty, "a menu build refused: \(fixture.heard)")
        #expect(built.captured == nil, "a menu build gave its caller a refusal")
    }

    /// Kind 4, `ActionTargetTitles.setState`: the row has the rule's check mark, and nobody hears a refusal.
    @Test func aStateRuleWhoseLookupMissesRefusesNothing() throws {
        let fixture = Fixture()
        ActionTargetTitles.setState(Self.row, in: fixture.registry) { [unowned fixture] _ in fixture.miss(); return true }
        let built = fixture.menuRow()
        let item = try #require(built.item, "the row is not in the menu")
        #expect(item.state == .on)
        #expect(fixture.asked > 0, "the menu did not ask the state rule")
        #expect(fixture.heard.isEmpty, "a menu build refused: \(fixture.heard)")
        #expect(built.captured == nil, "a menu build gave its caller a refusal")
    }

    /// Kind 5, `ActionTargetTitles.setChoiceState`: the choices submenu (a workspace row's color
    /// choices) asks which value is checked, and nobody hears a refusal.
    @Test func aChoiceRuleWhoseLookupMissesRefusesNothing() throws {
        let fixture = Fixture()
        let color: ActionID = "palette.workspaceColor"
        fixture.registry.bind(color, invoke: { _ in })
        ActionTargetTitles.setChoiceState(color, in: fixture.registry) { [unowned fixture] _ in fixture.miss(); return nil }
        var menu: NSMenu?
        let captured = fixture.registry.capturingRefusal {
            menu = fixture.registry.makeChoicesMenu(for: color, in: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "gone"))
        }
        let choices = try #require(menu, "the workspace row has no color choices here")
        #expect(!choices.items.isEmpty)
        #expect(fixture.asked > 0, "the choices submenu did not ask the choice rule")
        #expect(fixture.heard.isEmpty, "a choices build refused: \(fixture.heard)")
        #expect(captured == nil, "a choices build gave its caller a refusal")
    }

    /// The right refusal stays: a run on a target with a reason is refused with the RULE's reason
    /// (not the lookup's words, and not as `not found`), one time.
    @Test func aRunIsStillRefusedWithTheRulesOwnReason() throws {
        let fixture = Fixture()
        ActionTargetReasons.set(Self.run, in: fixture.registry) { [unowned fixture] _ in fixture.miss(); return Self.why }
        var ran = true
        let refusal = fixture.registry.capturingTypedRefusal {
            ran = fixture.registry.perform(Self.run, invocation: ActionInvocation(target: Self.target, origin: .user))
        }
        #expect(!ran)
        #expect(fixture.runs == 0, "the refused action ran")
        let got = try #require(refusal, "the caller of a refused run got no reason")
        #expect(got.reason == Self.why)
        #expect(!got.isNotFound, "the caller was told `not found` by a rule's lookup")
        #expect(fixture.heard == [Self.why])
    }

    /// A run whose reason rule found no reason runs, and its caller hears no refusal from the
    /// rule's lookup: the handler reports its own.
    @Test func aRunWhoseRuleGaveNoReasonRunsWithNoRefusal() {
        let fixture = Fixture()
        ActionTargetReasons.set(Self.run, in: fixture.registry) { [unowned fixture] _ in fixture.miss(); return nil }
        var ran = false
        let refusal = fixture.registry.capturingRefusal {
            ran = fixture.registry.perform(Self.run, invocation: ActionInvocation(target: Self.target, origin: .user))
        }
        #expect(ran)
        #expect(fixture.runs == 1)
        #expect(fixture.asked > 0, "the run did not ask the reason rule")
        #expect(refusal == nil, "a run that ran told its caller \(refusal ?? "")")
        #expect(fixture.heard.isEmpty, "a run that ran refused: \(fixture.heard)")
    }

    /// What changes for a caller (the CLI, MCP): a run whose rule's lookup missed and gave no
    /// reason, and whose handler then refuses, gets the HANDLER's refusal. It got the lookup's
    /// words before, typed `not found`. The row prints both texts.
    @Test func aCallerGetsTheHandlersRefusalNotTheRulesLookup() throws {
        let fixture = Fixture()
        let handlers = "This window cannot be minimized."
        fixture.onRun = { [unowned fixture] in fixture.registry.refuse(handlers) }
        ActionTargetReasons.set(Self.run, in: fixture.registry) { [unowned fixture] _ in fixture.miss(); return nil }
        let refusal = fixture.registry.capturingTypedRefusal {
            fixture.registry.perform(Self.run, invocation: ActionInvocation(target: Self.target, origin: .cli))
        }
        let got = try #require(refusal, "the caller of a refused run got no reason")
        print("question-rules: the caller got \"\(got.reason)\" (not found: \(got.isNotFound)); the lookup said \"\(Self.gone)\"; the handler said \"\(handlers)\"")
        #expect(got.reason == handlers)
        #expect(!got.isNotFound, "the caller was told `not found` by a rule's lookup")
        #expect(fixture.heard == [handlers])
    }

    /// A question inside a person's run leaves that run as it was: a rule's lookup that a
    /// `refusalDeferrals` entry would hold does not hold the run (no replay of it later), and the
    /// run's own refusal still shows.
    @Test func aQuestionInsideAPersonsRunDoesNotHoldTheRun() {
        let fixture = Fixture()
        var held: [ActionID] = []
        fixture.registry.refusalDeferrals.append { id, _, reason in
            guard reason == Self.gone else { return false }
            held.append(id)
            return true
        }
        ActionTargetVisibility.hide(Self.row, in: fixture.registry) { [unowned fixture] _ in fixture.miss(); return true }
        fixture.onRun = { [unowned fixture] in
            _ = fixture.registry.makeContextMenu(for: .tab, target: Self.target)
            fixture.registry.refuse(Self.why)
        }
        fixture.registry.perform(Self.run, invocation: ActionInvocation(origin: .user))
        #expect(fixture.runs == 1)
        #expect(fixture.asked > 0, "the run's menu build did not ask the hide rule")
        #expect(held.isEmpty, "a question held the person's run of \(held)")
        #expect(fixture.heard == [Self.why], "the run's own refusal was lost: \(fixture.heard)")
    }
}
