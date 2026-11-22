import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// R136 (Lawrence): a navigation or focus move with no target (no pane to
/// the right, the tab is already at the edge, nothing was closed) shows no
/// notice from the keyboard or a menu. The action still refuses: a CLI,
/// MCP, socket or palette caller gets the same reason.
@MainActor
struct QuietRefusalTests {
    @Test func aQuietRefusalReachesCallersButShowsNoNotice() {
        let services = KeyOwnershipMatrixTests.services()
        let registry = services.registry
        let context = AppActionContext(services: services)
        registry.bind("focusRight", invoke: { _ in context.refuseQuietly(RefusalStrings.noPaneInDirection(RefusalStrings.directionRight)) })
        let captured = registry.capturingRefusal { registry.perform("focusRight") }
        #expect(captured == RefusalStrings.noPaneInDirection(RefusalStrings.directionRight), "the CLI still gets the reason")
        var quiet: [Bool] = []
        registry.refusalObserver = { _, isQuiet in quiet.append(isQuiet) }
        registry.perform("focusRight")
        #expect(quiet == [true])
        // The HUD rule: a quiet refusal shows nothing; others show unless a caller has them.
        #expect(!AppActionContext.showsNotice(quiet: true, hasCaller: false))
        #expect(AppActionContext.showsNotice(quiet: false, hasCaller: false))
        #expect(!AppActionContext.showsNotice(quiet: false, hasCaller: true))
    }

    @Test func theRegistryTellsObserversWhichRefusalsAreQuiet() {
        let registry = ActionRegistry.standard()
        var observed: [(String, Bool)] = []
        registry.refusalObserver = { observed.append(($0, $1)) }
        registry.refuse("loud")
        registry.refuse("quiet", quiet: true)
        #expect(observed.map(\.0) == ["loud", "quiet"])
        #expect(observed.map(\.1) == [false, true])
    }
}
