import CmuxNextActions
import Testing
@testable import CmuxNextApp

/// The Home top page has no pane, so its `surfaceKind` comes from the top
/// page the window shows: `home`, the context Home's bindings name.
@MainActor
@Suite struct HomeKeyContextTests {
    @Test func theHomeTopPageIsSurfaceKindHome() {
        let context = KeyRouter.keyContext(for: FocusState(), appContext: [], facts: KeyRouter.Facts(topPage: "home"))
        #expect(context[KeyContext.surfaceKind] == .string("home"))
        #expect(context[KeyContext.topPage] == .string("home"))
        let terminal = KeyRouter.keyContext(for: KeyOwnershipMatrixTests.terminal, appContext: [], facts: KeyRouter.Facts())
        #expect(terminal[KeyContext.surfaceKind] == .string("terminal"))
        #expect(terminal[KeyContext.topPage] == nil)
    }
}
