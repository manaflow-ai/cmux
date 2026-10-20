@testable import CmuxControlSocket

extension ControlSimulatorContext {
    func controlSimulatorBeginType(
        routing: ControlRoutingSelectors,
        text: String
    ) -> ControlSimulatorTypeStartResolution { .failed(.tabManagerUnavailable) }

    func controlSimulatorBeginWebInspectorTargets(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution { .failed(.tabManagerUnavailable) }

    func controlSimulatorBeginWebInspectorAttach(
        routing: ControlRoutingSelectors,
        targetID: String
    ) -> ControlSimulatorWebInspectorStartResolution { .failed(.tabManagerUnavailable) }

    func controlSimulatorBeginWebInspectorSend(
        routing: ControlRoutingSelectors,
        json: String
    ) -> ControlSimulatorWebInspectorStartResolution { .failed(.tabManagerUnavailable) }

    func controlSimulatorBeginWebInspectorHighlight(
        routing: ControlRoutingSelectors,
        enabled: Bool
    ) -> ControlSimulatorWebInspectorStartResolution { .failed(.tabManagerUnavailable) }

    func controlSimulatorBeginWebInspectorRelease(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution { .failed(.tabManagerUnavailable) }

    func controlSimulatorBeginOperation(
        routing: ControlRoutingSelectors,
        operation: ControlSimulatorOperation
    ) -> ControlSimulatorOperationStartResolution { .failed(.tabManagerUnavailable) }
}
