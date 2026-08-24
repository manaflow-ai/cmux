/// App-state seam for native Simulator text input and Web Inspector control.
@MainActor
public protocol ControlSimulatorContext: AnyObject {
    /// Starts delivery of text to the resolved Simulator surface.
    func controlSimulatorBeginType(
        routing: ControlRoutingSelectors,
        text: String
    ) -> ControlSimulatorTypeStartResolution

    /// Starts a refresh of the resolved Simulator's inspectable WebKit targets.
    func controlSimulatorBeginWebInspectorTargets(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution

    /// Attaches Web Inspector to a target on the resolved Simulator surface.
    func controlSimulatorBeginWebInspectorAttach(
        routing: ControlRoutingSelectors,
        targetID: String
    ) -> ControlSimulatorWebInspectorStartResolution

    /// Sends a JSON message through the resolved Web Inspector session.
    func controlSimulatorBeginWebInspectorSend(
        routing: ControlRoutingSelectors,
        json: String
    ) -> ControlSimulatorWebInspectorStartResolution

    /// Enables or disables highlighting for the attached Web Inspector target.
    func controlSimulatorBeginWebInspectorHighlight(
        routing: ControlRoutingSelectors,
        enabled: Bool
    ) -> ControlSimulatorWebInspectorStartResolution

    /// Releases the resolved Simulator's Web Inspector session.
    func controlSimulatorBeginWebInspectorRelease(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution

    /// Starts a native operation on the resolved Simulator surface.
    func controlSimulatorBeginOperation(
        routing: ControlRoutingSelectors,
        operation: ControlSimulatorOperation
    ) -> ControlSimulatorOperationStartResolution
}
