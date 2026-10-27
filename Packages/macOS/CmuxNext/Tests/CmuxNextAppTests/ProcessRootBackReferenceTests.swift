import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDaemonService
import Testing

/// p10-stability-091: the objects under the process root hold it strongly, so none of them can read a
/// freed owner (an `unowned` read after its owner's deinit traps). A key router keeps the registry it was
/// made with, and a page service keeps answering after the last outside reference to its services is gone.
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

    @Test(.timeLimit(.minutes(1)))
    func aPageServiceAnswersAfterItsServicesLastOutsideReferenceIsGone() throws {
        _ = NSApplication.shared
        weak var released: AppServices?
        let inbox: FeedPageService = autoreleasepool {
            let services = AppServices(environment: AppEnvironment.current([:]))
            released = services
            return services.feedPage
        }
        try #require(released != nil, "the page service holds its services; an unowned one would trap on the next read")
        // No window is open: the open refuses with its message instead of trapping on a freed owner.
        #expect(throws: ActionFailure.self) { try inbox.open(focus: false) }
    }
}
