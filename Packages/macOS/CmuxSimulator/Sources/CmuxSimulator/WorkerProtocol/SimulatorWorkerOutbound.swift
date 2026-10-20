import Foundation

/// A typed event emitted by the isolated Simulator worker.
public enum SimulatorWorkerOutbound: Codable, Equatable, Sendable {
    /// Acknowledges an ordered host ping after all earlier commands were handled.
    case ack(UInt64)
    /// Announces a permission-restricted packed-frame shared-memory ring.
    case frameTransport(SimulatorFrameTransportDescriptor)
    /// Reports a session lifecycle transition.
    case status(SimulatorSessionStatus)
    /// Reports negotiated private and supported capabilities.
    case capabilities(Set<SimulatorCapability>)
    /// Reports the final capability set after optional attachment probes finish.
    case capabilitiesHydrated(Set<SimulatorCapability>)
    /// Reports current framebuffer dimensions and orientation.
    case display(SimulatorDisplayMetadata)
    /// Reports native host-input capture, including Escape-driven release.
    case hidCapture(SimulatorHIDCaptureMode)
    /// Delivers a requested accessibility tree.
    case accessibility(requestID: UUID, SimulatorAccessibilitySnapshot)
    /// Delivers requested foreground-application metadata.
    case foregroundApplication(requestID: UUID, SimulatorApplicationInfo?)
    /// Delivers a failure correlated to one request without timing out or
    /// invalidating an otherwise healthy worker generation.
    case requestFailure(requestID: UUID, SimulatorFailure)
    /// Delivers a correlated permission-status snapshot.
    case privacy(requestID: UUID, SimulatorPrivacySnapshot)
    /// Confirms a correlated private permission mutation.
    case privatePrivacy(requestID: UUID, succeeded: Bool)
    /// Confirms a correlated React Native reload attempt.
    case reactNativeReload(requestID: UUID, succeeded: Bool)
    /// Confirms that an accessibility highlight was applied or cleared.
    case accessibilityHighlight(requestID: UUID, applied: Bool)
    /// Confirms whether an ordered text-input sequence finished transmission.
    case textInput(requestID: UUID, succeeded: Bool)
    /// Transfers cleanup ownership before camera injection mutates an app.
    case cameraTargetResolved(requestID: UUID, bundleIdentifier: String)
    /// Confirms that a worker-timed wheel burst no longer holds a touch.
    case scrollWheelEnded(eventID: UUID)
    /// Confirms a correlated native input or diagnostic action.
    case interactiveAction(requestID: UUID, succeeded: Bool)
    /// Confirms a source-independent camera mirror update.
    case cameraMirror(requestID: UUID, succeeded: Bool)
    /// Confirms camera source setup, injection, and target validation.
    case cameraConfiguration(
        requestID: UUID,
        succeeded: Bool,
        targetBundleIdentifier: String?
    )
    /// Delivers a correlated camera adapter snapshot.
    case cameraStatus(requestID: UUID, SimulatorCameraStatus)
    /// Confirms camera and inspector state no longer owns an app lifecycle.
    case applicationMutationPrepared(requestID: UUID, succeeded: Bool)
    /// Confirms a correlated live private interface update.
    case privateInterface(requestID: UUID, succeeded: Bool)
    /// Delivers correlated live private interface values.
    case privateInterfaceStatus(requestID: UUID, SimulatorInterfaceStatus)
    /// Delivers a target snapshot. A nil request identity is a live catalog update.
    case webInspectorTargets(requestID: UUID?, [SimulatorWebInspectorTarget])
    /// Confirms attachment/release or reports an asynchronous session transition.
    case webInspectorSession(requestID: UUID?, SimulatorWebInspectorSessionStatus)
    /// Confirms whether a raw inspector command entered the bounded session router.
    case webInspectorCommand(requestID: UUID, accepted: Bool)
    /// Confirms a correlated page highlight update.
    case webInspectorHighlight(requestID: UUID, succeeded: Bool)
    /// Streams one bounded chunk of a raw inspector response or event.
    case webInspectorMessage(SimulatorWebInspectorMessageChunk)
    /// Appends a bounded action-history entry.
    case actionLog(SimulatorActionLogEntry)
    /// Reports a recoverable or terminal failure without crashing cmux.
    case failure(SimulatorFailure)
}

extension SimulatorWorkerOutbound {
    /// Correlation identifier carried by request/response worker messages.
    public var requestIdentifier: UUID? {
        switch self {
        case let .accessibility(requestID, _),
             let .foregroundApplication(requestID, _),
             let .requestFailure(requestID, _),
             let .privacy(requestID, _),
             let .privatePrivacy(requestID, _),
             let .reactNativeReload(requestID, _),
             let .accessibilityHighlight(requestID, _),
             let .textInput(requestID, _),
             let .cameraTargetResolved(requestID, _),
             let .interactiveAction(requestID, _),
             let .cameraMirror(requestID, _),
             let .cameraConfiguration(requestID, _, _),
             let .cameraStatus(requestID, _),
             let .applicationMutationPrepared(requestID, _),
             let .privateInterface(requestID, _),
             let .privateInterfaceStatus(requestID, _),
             let .webInspectorCommand(requestID, _),
             let .webInspectorHighlight(requestID, _):
            requestID
        case let .webInspectorTargets(requestID, _),
             let .webInspectorSession(requestID, _):
            requestID
        default:
            nil
        }
    }
}
