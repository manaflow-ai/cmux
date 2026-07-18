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

    @Test
    func aNewPressCleansUpThePreviousActivationSynchronously() {
        let interaction = SignalClickDragInteraction<String, Int>()
        var cleanedActivationIDs: [String] = []
        let effect = interaction.observePhase { phase, context in
            guard case let .activating(id, _) = phase else { return }
            context.onCleanup {
                cleanedActivationIDs.append(id)
            }
        }

        interaction.mouseDown(on: "workspace-a", context: 7)
        _ = interaction.mouseUpWithoutDrag(on: "workspace-a")
        interaction.mouseDown(on: "workspace-b", context: 8)

        #expect(cleanedActivationIDs == ["workspace-a"])
        #expect(interaction.phase == .pressed(id: "workspace-b", context: 8))
        withExtendedLifetime(effect) {}
    }
}
