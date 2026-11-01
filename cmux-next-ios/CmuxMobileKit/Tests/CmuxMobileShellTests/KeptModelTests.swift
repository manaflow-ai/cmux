#if os(iOS)
import Testing
@testable import CmuxMobileShell

/// RootView re-creates the signed-in shell on every update; only the first creation may build the model.
@MainActor @Suite struct KeptModelTests {
    private final class Model {}

    @Test func laterCreationsGetTheFirstModelWithoutBuildingAnother() {
        let kept = KeptModel<Model>()
        var built = 0
        let first = kept.model { built += 1; return Model() }
        let second = kept.model { built += 1; return Model() }
        #expect(first === second)
        #expect(built == 1)
    }

    @Test func discardingStartsTheNextShellFresh() {
        let kept = KeptModel<Model>()
        let first = kept.model { Model() }
        kept.discard()
        #expect(kept.model { Model() } !== first)
    }

    @Test func discardCleansTheOutgoingModelBeforeDroppingIt() {
        let kept = KeptModel<Model>()
        let first = kept.model { Model() }
        var cleaned: Model?
        kept.discard { cleaned = $0 }
        #expect(cleaned === first)
        #expect(kept.model { Model() } !== first)
    }
}
#endif
