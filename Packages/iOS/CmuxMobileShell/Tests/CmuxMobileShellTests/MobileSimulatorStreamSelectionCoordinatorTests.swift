import Testing
@testable import CmuxMobileShell

@MainActor
private final class MobileSimulatorStreamSelectionCoordinatorBox {
    var value: MobileSimulatorStreamSelectionCoordinator?
}

@MainActor
@Suite struct MobileSimulatorStreamSelectionCoordinatorTests {
    @Test func rapidPendingSelectionsStartOnlyTheLatestTarget() async {
        var operations: [MobileSimulatorStreamSelectionCoordinator.Operation] = []
        let coordinator = MobileSimulatorStreamSelectionCoordinator {
            operations.append($0)
        }

        coordinator.requestTransition(from: "sim-a", to: "sim-b", workspaceID: "workspace-1")
        coordinator.requestTransition(from: "sim-b", to: "sim-c", workspaceID: "workspace-1")
        await coordinator.waitForIdle()

        #expect(operations == [
            .stop(panelID: "sim-a", workspaceID: "workspace-1"),
            .start(panelID: "sim-c", workspaceID: "workspace-1"),
        ])
    }

    @Test func selectionArrivingDuringStartStopsTheAcceptedStaleTarget() async {
        var operations: [MobileSimulatorStreamSelectionCoordinator.Operation] = []
        let box = MobileSimulatorStreamSelectionCoordinatorBox()
        let coordinator = MobileSimulatorStreamSelectionCoordinator { operation in
            operations.append(operation)
            if operation == .start(panelID: "sim-b", workspaceID: "workspace-1") {
                box.value?.requestTransition(
                    from: "sim-b",
                    to: "sim-c",
                    workspaceID: "workspace-1"
                )
            }
        }
        box.value = coordinator

        coordinator.requestTransition(from: "sim-a", to: "sim-b", workspaceID: "workspace-1")
        await coordinator.waitForIdle()

        #expect(operations == [
            .stop(panelID: "sim-a", workspaceID: "workspace-1"),
            .start(panelID: "sim-b", workspaceID: "workspace-1"),
            .stop(panelID: "sim-b", workspaceID: "workspace-1"),
            .start(panelID: "sim-c", workspaceID: "workspace-1"),
        ])
    }

    @Test func selectionArrivingDuringStopDoesNotStopANeverStartedTarget() async {
        var operations: [MobileSimulatorStreamSelectionCoordinator.Operation] = []
        let box = MobileSimulatorStreamSelectionCoordinatorBox()
        let coordinator = MobileSimulatorStreamSelectionCoordinator { operation in
            operations.append(operation)
            if operation == .stop(panelID: "sim-a", workspaceID: "workspace-1") {
                box.value?.requestTransition(
                    from: "sim-b",
                    to: "sim-c",
                    workspaceID: "workspace-1"
                )
            }
        }
        box.value = coordinator

        coordinator.requestTransition(from: "sim-a", to: "sim-b", workspaceID: "workspace-1")
        await coordinator.waitForIdle()

        #expect(operations == [
            .stop(panelID: "sim-a", workspaceID: "workspace-1"),
            .start(panelID: "sim-c", workspaceID: "workspace-1"),
        ])
    }

    @Test func cancellationCleansUpAStartThatWasAlreadyAccepted() async {
        var operations: [MobileSimulatorStreamSelectionCoordinator.Operation] = []
        let box = MobileSimulatorStreamSelectionCoordinatorBox()
        let coordinator = MobileSimulatorStreamSelectionCoordinator { operation in
            operations.append(operation)
            if operation == .start(panelID: "sim-b", workspaceID: "workspace-1") {
                box.value?.cancel()
            }
        }
        box.value = coordinator

        coordinator.requestTransition(from: "sim-a", to: "sim-b", workspaceID: "workspace-1")
        await coordinator.waitForIdle()

        #expect(operations == [
            .stop(panelID: "sim-a", workspaceID: "workspace-1"),
            .start(panelID: "sim-b", workspaceID: "workspace-1"),
            .stop(panelID: "sim-b", workspaceID: "workspace-1"),
        ])
    }
}
