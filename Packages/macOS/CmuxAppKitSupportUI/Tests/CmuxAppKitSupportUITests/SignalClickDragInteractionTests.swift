import Testing
@testable import CmuxAppKitSupportUI

@Suite
@MainActor
struct SignalClickDragInteractionTests {
    @Test
    func mouseUpWithoutDragCommitsActivation() {
        let interaction = SignalClickDragInteraction<String, Int>()
        var observedPhases: [SignalClickDragPhase<String, Int>] = []
        let effect = interaction.observePhase { phase, _ in
            observedPhases.append(phase)
        }

        interaction.mouseDown(on: "workspace-a", context: 7)
        let activation = interaction.mouseUpWithoutDrag(on: "workspace-a")

        #expect(activation?.id == "workspace-a")
        #expect(activation?.context == 7)
        #expect(interaction.phase == .activating(id: "workspace-a", context: 7))
        #expect(observedPhases == [
            .idle,
            .pressed(id: "workspace-a", context: 7),
            .activating(id: "workspace-a", context: 7),
        ])
        _ = effect
    }

    @Test
    func crossingDragThresholdSuppressesActivationAndReturnsToIdleOnDragEnd() {
        let interaction = SignalClickDragInteraction<String, Int>()

        interaction.mouseDown(on: "workspace-a", context: 7)
        #expect(interaction.dragDidBegin(on: "workspace-a"))
        #expect(interaction.phase == .dragging(id: "workspace-a", context: 7))
        #expect(interaction.mouseUpWithoutDrag(on: "workspace-a") == nil)

        interaction.dragDidEnd()

        #expect(interaction.phase == .idle)
    }

    @Test
    func endingTrackingWithoutClickOrDragCancelsThePress() {
        let interaction = SignalClickDragInteraction<String, Int>()

        interaction.mouseDown(on: "workspace-a", context: 7)
        interaction.trackingDidEnd()

        #expect(interaction.phase == .idle)
    }
}
