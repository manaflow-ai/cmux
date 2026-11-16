import AppKit
import CmuxNextActions
@testable import CmuxNextDaemonService
import CmuxNextPalette
import Testing

/// A floating pane has no zoom (`FloatingPaneActions.withholdZoom`): the key does nothing there, the palette does
/// not offer the row, a floating pane's menu and toolbar leave the action out, and a run that names a floating
/// pane is refused. A tiled pane keeps its zoom.
@MainActor struct FloatingPaneZoomTests {
    @MainActor final class Fixture {
        let registry = ActionRegistry.standard()
        /// Whether the pane of an invocation floats.
        var floats = false
        var zooms = 0

        init() {
            registry.context = ActionContext(rawValue: .max)
            registry.bindEffect("toggleSplitZoom", effect: { [unowned self] _ in
                zooms += 1
                return .done
            })
            FloatingPaneActions.withholdZoom(in: registry) { [unowned self] _ in floats }
        }

        var paletteOffersZoom: Bool {
            RegistryPaletteProvider(registry: registry).makeItems().contains { $0.id == "action:toggleSplitZoom" }
        }
    }

    let named = ActionInvocation(target: ActionTargetRef(kind: .pane, id: "pane"))

    @Test func theZoomKeyDoesNothingOnAFloatingPane() {
        let fixture = Fixture()
        fixture.registry.perform("toggleSplitZoom")
        #expect(fixture.zooms == 1, "a tiled pane zooms")
        fixture.floats = true
        var refusals: [String] = []
        fixture.registry.refusalObserver = { reason, _ in refusals.append(reason) }
        fixture.registry.perform("toggleSplitZoom")
        #expect(fixture.zooms == 1, "a floating pane does not")
        #expect(refusals.isEmpty, "and the key shows no notice")
        #expect(!fixture.registry.perform("toggleSplitZoom", invocation: named), "a run that names a floating pane is refused")
        #expect(fixture.zooms == 1)
        fixture.floats = false
        #expect(fixture.registry.perform("toggleSplitZoom", invocation: named))
        #expect(fixture.zooms == 2)
    }

    @Test func thePaletteDoesNotOfferZoomWhileTheFocusedPaneFloats() {
        let fixture = Fixture()
        #expect(fixture.paletteOffersZoom)
        fixture.floats = true
        #expect(!fixture.paletteOffersZoom, "no row that does nothing")
        fixture.floats = false
        #expect(fixture.paletteOffersZoom)
    }

    @Test func aFloatingPanesMenuAndToolbarLeaveZoomOut() throws {
        let fixture = Fixture()
        let zoom = try #require(fixture.registry.action(for: "toggleSplitZoom"))
        #expect(zoom.targetHidden?(named) == false)
        #expect(ActionTargetReasons.canPerform("toggleSplitZoom", invocation: named, in: fixture.registry))
        fixture.floats = true
        #expect(zoom.targetHidden?(named) == true, "the context menu leaves the row out")
        #expect(!ActionTargetReasons.canPerform("toggleSplitZoom", invocation: named, in: fixture.registry), "the toolbar leaves its button out")
        #expect(zoom.targetUnavailableReason?(ActionInvocation()) == nil, "the key's run is not refused: it does nothing")
    }
}
