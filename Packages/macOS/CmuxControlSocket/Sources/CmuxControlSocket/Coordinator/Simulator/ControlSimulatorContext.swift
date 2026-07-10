/// App-state seam for native Simulator text input and Web Inspector control.
@MainActor
public protocol ControlSimulatorContext: AnyObject {
    func controlSimulatorBeginType(
        routing: ControlRoutingSelectors,
        text: String
    ) -> ControlSimulatorTypeStartResolution

    func controlSimulatorBeginWebInspectorTargets(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution

    func controlSimulatorBeginWebInspectorAttach(
        routing: ControlRoutingSelectors,
        targetID: String
    ) -> ControlSimulatorWebInspectorStartResolution

    func controlSimulatorBeginWebInspectorSend(
        routing: ControlRoutingSelectors,
        json: String
    ) -> ControlSimulatorWebInspectorStartResolution

    func controlSimulatorBeginWebInspectorHighlight(
        routing: ControlRoutingSelectors,
        enabled: Bool
    ) -> ControlSimulatorWebInspectorStartResolution

    func controlSimulatorBeginWebInspectorRelease(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution

    func controlSimulatorBeginOperation(
        routing: ControlRoutingSelectors,
        operation: ControlSimulatorOperation
    ) -> ControlSimulatorOperationStartResolution
}

public enum ControlSimulatorLimits {
    /// Maximum UTF-8 payload accepted by `simulator.type`.
    public static let maximumTextUTF8ByteCount = 4_096
    /// Maximum UTF-8 JSON payload accepted by Web Inspector commands.
    public static let maximumWebInspectorJSONByteCount = 1_024 * 1_024
    /// Maximum UTF-8 length accepted for an app bundle identifier.
    public static let maximumBundleIdentifierUTF8ByteCount = 255
    /// Maximum UTF-8 length accepted for a canonical permission or interface token.
    public static let maximumCommandTokenUTF8ByteCount = 64
}
