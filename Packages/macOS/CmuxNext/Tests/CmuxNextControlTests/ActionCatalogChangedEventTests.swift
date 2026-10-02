@testable import CmuxNextControl
import Testing

/// `cmux mcp serve` re-lists its action tools on `action.catalog.changed`
/// (plans/cmux-next/mcp.md), so the router must publish it exactly when the
/// actions change.
@Suite struct ActionCatalogChangedEventTests {
    @MainActor @Test func publishesOnlyWhenTheActionsChange() {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), settings: nil)
        let start = router.events.latestSequence

        router.updateCatalog(sampleCatalog())
        #expect(router.events.latestSequence == start + 1)

        router.updateCatalog(sampleCatalog())
        router.updateContextMask(0b1)
        #expect(router.events.latestSequence == start + 1, "an unchanged catalog or a context change is not an event")

        var changed = sampleCatalog()
        changed.actions[0].isCLI.toggle()
        router.updateCatalog(changed)
        #expect(router.events.latestSequence == start + 2)
    }
}
