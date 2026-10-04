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
        context.observeRefusals()
        registry.bind("focusRight", invoke: { _ in context.refuseQuietly(RefusalStrings.noPaneInDirection(RefusalStrings.directionRight)) })
        let captured = registry.capturingRefusal { registry.perform("focusRight") }
        #expect(captured == RefusalStrings.noPaneInDirection(RefusalStrings.directionRight), "the CLI still gets the reason")
        registry.perform("focusRight")
        #expect(services.refusalHUD.message == nil, "the keyboard run shows nothing")

        registry.bind("closeTab", invoke: { _ in context.refuse("a refusal the user must act on") })
        registry.perform("closeTab")
        #expect(services.refusalHUD.message == "a refusal the user must act on", "other refusals keep their notice")
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
