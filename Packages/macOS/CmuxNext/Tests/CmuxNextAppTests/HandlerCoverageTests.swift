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
}
