import AppKit
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
}
