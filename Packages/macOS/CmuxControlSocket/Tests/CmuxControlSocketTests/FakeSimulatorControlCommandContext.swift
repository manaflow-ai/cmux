@testable import CmuxControlSocket

@MainActor
final class FakeSimulatorControlCommandContext: ControlCommandContext {
    var typeResolution: ControlSimulatorTypeStartResolution = .failed(.tabManagerUnavailable)
    var webResolution: ControlSimulatorWebInspectorStartResolution = .failed(.tabManagerUnavailable)
    var operationResolution: ControlSimulatorOperationStartResolution = .failed(.tabManagerUnavailable)
    var lastText: String?
    var lastTargetID: String?
    var lastJSON: String?
    var lastHighlight: Bool?
    var lastOperation: ControlSimulatorOperation?

    func controlSimulatorBeginType(
        routing: ControlRoutingSelectors,
        text: String
    ) -> ControlSimulatorTypeStartResolution {
        lastText = text
        return typeResolution
    }

    func controlSimulatorBeginWebInspectorTargets(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution { webResolution }

    func controlSimulatorBeginWebInspectorAttach(
        routing: ControlRoutingSelectors,
        targetID: String
    ) -> ControlSimulatorWebInspectorStartResolution {
        lastTargetID = targetID
        return webResolution
    }

    func controlSimulatorBeginWebInspectorSend(
        routing: ControlRoutingSelectors,
        json: String
    ) -> ControlSimulatorWebInspectorStartResolution {
        lastJSON = json
        return webResolution
    }

    func controlSimulatorBeginWebInspectorHighlight(
        routing: ControlRoutingSelectors,
        enabled: Bool
    ) -> ControlSimulatorWebInspectorStartResolution {
        lastHighlight = enabled
        return webResolution
    }

    func controlSimulatorBeginWebInspectorRelease(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution { webResolution }

    func controlSimulatorBeginOperation(
        routing: ControlRoutingSelectors,
        operation: ControlSimulatorOperation
    ) -> ControlSimulatorOperationStartResolution {
        lastOperation = operation
        return operationResolution
    }
}
