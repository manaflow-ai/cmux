import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDaemonService
import Testing

/// A service's back-reference to the `AppServices` that owns it does not own it (an owner holds its
/// children, a child's back-pointer never keeps its owner, as Chromium's `raw_ptr` back-pointers), and a call that
/// reaches a service after its services are gone refuses instead of trapping (an `unowned` read traps there).
@MainActor struct ProcessRootBackReferenceTests {
    @Test func aKeyRouterKeepsTheRegistryItWasMadeWith() throws {
        weak var released: ActionRegistry?
        let router: KeyRouter = autoreleasepool {
            let registry = ActionRegistry.standard()
            released = registry
            return KeyRouter(registry: registry)
        }
        try #require(released != nil, "the router holds its registry; an unowned one is freed here and the next read traps")
        #expect(router.registry === released)
    }

    /// Fails on the strong back-references this task first tried: every `AppServices` a test built then lived for the
    /// rest of the test process, its observers still live.
    @Test(.timeLimit(.minutes(1)))
    func aPageServiceDoesNotKeepItsServicesAndRefusesOnceTheyAreGone() throws {
        _ = NSApplication.shared
        weak var released: AppServices?
        let inbox: FeedPageService = autoreleasepool {
            let services = AppServices(environment: AppEnvironment.current([:]))
            released = services
            return services.feedPage
        }
        try #require(released == nil, "the page service holds its services weakly: they go with their last outside reference")
        let refusal = #expect(throws: ActionFailure.self) { try inbox.open(focus: false) }
        #expect(refusal?.message == RefusalStrings.appClosing)
    }
}
