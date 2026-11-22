import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Keeps catalog additions from reaching the Debug app's launch assertion
/// without a matching App handler.
@MainActor
struct HandlerCoverageTests {
    @Test func everyTabPaneScreenAndTerminalActionHasAnAppHandler() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)

        HandlerCoverage.verify(services.registry)
        let missing = services.registry.unboundActionIDs(in: HandlerCoverage.categories)
        #expect(missing.isEmpty, "catalog actions without App handlers: \(missing.map(\.rawValue).joined(separator: ", "))")
    }

    /// A same-tree build loads the tree's catalog, which can hold terminal rows the FFI step
    /// added before the App's handlers (#38590 step A, #43840): they bind unavailable, so the
    /// Debug app still launches.
    @Test func terminalRowsAheadOfTheirHandlersStillHaveOne() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let ids: [ActionID] = ["terminal.fixLastCommand", "terminal.sendLastOutputToChat", "terminal.sendSelectionToChat"]
        services.registry.seed(ids.map { ActionDescriptor(id: $0, title: $0.rawValue, category: .terminal) })
        AppActions.bind(services)

        let missing = services.registry.unboundActionIDs(in: HandlerCoverage.categories)
        #expect(missing.isEmpty, "catalog actions without App handlers: \(missing.map(\.rawValue).joined(separator: ", "))")
    }

    /// A same-tree build can load a catalog that holds the floating pane rows before the App's
    /// handlers for them (decision 2026-11-17: the catalog rows land first). They bind unavailable
    /// and stay out of each menu, so the Debug app still launches and no menu offers a row that
    /// cannot run. The ids are the list of the placeholders: the change that binds a real handler
    /// takes its id out of that list, or this test is red for that id.
    @Test func floatingPaneRowsAheadOfTheirHandlersStillHaveOne() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let ids = FloatingPanePlaceholders.ids
        services.registry.seed(ids.map { ActionDescriptor(id: $0, title: $0.rawValue, category: .pane) })
        AppActions.bind(services)

        let missing = services.registry.unboundActionIDs(in: HandlerCoverage.categories)
        #expect(missing.isEmpty, "catalog actions without App handlers: \(missing.map(\.rawValue).joined(separator: ", "))")
        for id in ids {
            #expect(services.registry.unavailableReason(for: id) != nil, "\(id.rawValue) has no reason")
            #expect(services.registry.action(for: id)?.targetHidden?(ActionInvocation()) == true, "\(id.rawValue) is not hidden")
        }
    }
}
