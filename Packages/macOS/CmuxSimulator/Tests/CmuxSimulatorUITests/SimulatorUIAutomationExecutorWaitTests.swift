import CmuxControlSocket
import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI
@testable import CmuxSimulatorUIAutomation

@MainActor
@Suite("Simulator UI automation executor waits")
struct SimulatorUIAutomationExecutorWaitTests {
    @Test("Text-only gone waits reject heterogeneous matches")
    func textOnlyGoneRejectsAmbiguousMatches() async {
        let display = SimulatorDisplayMetadata(
            width: 1_170,
            height: 2_532,
            orientation: .portrait,
            scale: 3
        )
        let snapshot = SimulatorAccessibilitySnapshot(
            roots: [SimulatorAccessibilityNode(
                id: "root",
                role: "Application",
                label: "Example",
                value: nil,
                frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                isEnabled: true,
                children: [
                    SimulatorAccessibilityNode(
                        id: "pending",
                        role: "StaticText",
                        label: "Status pending",
                        value: nil,
                        frame: SimulatorRect(x: 20, y: 100, width: 160, height: 44),
                        isEnabled: true,
                        children: []
                    ),
                    SimulatorAccessibilityNode(
                        id: "complete",
                        role: "StaticText",
                        label: "Status complete",
                        value: nil,
                        frame: SimulatorRect(x: 20, y: 160, width: 160, height: 44),
                        isEnabled: true,
                        children: []
                    ),
                ]
            )],
            display: display
        )
        let client = SimulatorPaneClientSpy(
            devices: [],
            accessibilityResult: .accessibility(snapshot)
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.selectedDeviceID = "SIM-1"
        coordinator.capabilities = [.accessibility]
        coordinator.display = display
        let wait = ControlSimulatorUIWait(
            predicate: "gone",
            elementRef: nil,
            identifier: nil,
            label: nil,
            role: nil,
            value: nil,
            text: "Status",
            timeoutMilliseconds: 0,
            pollIntervalMilliseconds: 100,
            settledDurationMilliseconds: 0
        )

        do {
            _ = try await SimulatorUIAutomationExecutor().perform(
                .uiWait(wait),
                coordinator: coordinator
            )
            Issue.record("Expected an ambiguous wait failure")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "target_ambiguous")
        } catch {
            Issue.record("Expected target_ambiguous, got \(error)")
        }
        await coordinator.close()
    }
}
