@testable import CmuxNextActions
import Testing

/// Opening a projection window (HQ#7149 L10) is a view change by purpose: a `cmux action run` or socket run
/// of it shows its `page` in the new window. Without it the page show, run in the open's scope, did nothing.
struct ProjectionActionCatalogTests {
    @Test func openingAProjectionMayChangeTheViewFromAScript() throws {
        let open = try #require(ActionCatalog.all.first { $0.id.rawValue == "debug.projection" })
        #expect(open.focuses)
        for origin in [ActionOrigin.cli, .script] {
            #expect(ActionRunScope(ActionInvocation(origin: origin), focuses: open.focuses).allowsViewChange)
        }
    }
}
