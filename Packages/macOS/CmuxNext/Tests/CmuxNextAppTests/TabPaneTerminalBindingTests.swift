import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import Testing

/// Binding coverage for the tab (incl. tab groups), pane (incl. columns and
/// screens), and terminal actions, and their typed refusals.
@MainActor
struct TabPaneTerminalBindingTests {
    typealias Coverage = ActionBindingCoverageTests

    @Test func everyTabPaneAndTerminalActionIsBound() {
        let registry = Coverage.boundServices().registry
        let unbound = registry.unboundActionIDs(in: HandlerCoverage.categories)
        #expect(unbound.isEmpty, "unbound: \(unbound.map(\.rawValue).sorted())")
        #expect(HandlerCoverage.categories == [.tab, .pane, .screen, .terminal])
    }

    @Test func tabGroupsNeedTheDaemonCapability() {
        let services = Coverage.boundServices()
        let group = ActionTargetRef(kind: .tabGroup, id: "g1")
        for id in ["tabGroup.rename", "tabGroup.color.red", "tabGroup.moveLeft", "tabGroup.save"] {
            #expect(Coverage.run(services, id, target: group) == .refused("needs daemon capability tab-groups-v1"), "\(id)")
        }
    }

    @Test func unportedFeaturesSayWhatTheyNeed() {
        let services = Coverage.boundServices()
        #expect(Coverage.run(services, "toggleCanvasLayout") == .refused("needs canvas layout, which cmux-next does not have yet"))
        #expect(Coverage.run(services, "palette.copyPaneLink") == .refused("needs cmux-next deep link navigation (cmux:// handler)"))
    }

    @Test func missingTargetsAreRefusedNotSilentlyIgnored() {
        let services = Coverage.boundServices()
        #expect(Coverage.run(services, "closeTab") == .refused(MiscHandlerStrings.noPane))
        #expect(Coverage.run(services, "splitRight") == .refused(MiscHandlerStrings.noPane))
        #expect(Coverage.run(services, "column.center") == .refused(MiscHandlerStrings.noPane))
        #expect(Coverage.run(services, "column.center", target: ActionTargetRef(kind: .column, id: "c9")) == .refused("no column c9 is shown"))
        let missing = ActionTargetRef(kind: .tab, id: "missing")
        #expect(Coverage.run(services, "tab.moveToNewColumn", target: missing) == .refused("no tab missing"))
        #expect(Coverage.run(services, "reopenClosedBrowserPanel") == .refused("no recently closed tab"))
    }
}
