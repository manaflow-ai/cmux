import Foundation

/// A typed message sent from cmux to the isolated Simulator worker.
public enum SimulatorWorkerInbound: Codable, Equatable, Sendable {
    /// Proves that every command before `sequence` has reached the worker's ordered loop.
    case ping(UInt64)
    /// Attach to a booted device and start rendering.
    case attach(udid: String, geometry: SimulatorSurfaceGeometry?)
    /// Update the host pane size and backing scale.
    case resize(SimulatorSurfaceGeometry)
    /// Starts or stops framebuffer publication while preserving control state.
    case setFramebufferPublishing(Bool)
    /// Confirms the host mapped the current frame ring so older names can retire.
    case acknowledgeFrameTransport(SimulatorFrameTransportDescriptor)
    /// Forward one ordered touch event.
    case pointer(SimulatorPointerEvent)
    /// Forward one USB HID keyboard event.
    case key(SimulatorKeyEvent)
    /// Deliver one short, balanced key chord with worker-owned pacing.
    case keySequence([SimulatorKeyEvent])
    /// Merge one phase-less wheel delta into a worker-timed touch drag.
    case scrollWheel(SimulatorScrollWheelEvent)
    /// Deliver one prevalidated, bounded text sequence as an ordered worker command.
    case typeText(requestID: UUID, sequence: SimulatorTextInputSequence)
    /// Execute one correlated, bounded native input or diagnostic action.
    case interactiveAction(requestID: UUID, action: SimulatorInteractiveAction)
    /// Press a hardware or system button.
    case button(SimulatorHardwareButton)
    /// Forward one raw DeviceKit HID button phase without synthesizing a tap.
    case hidButton(SimulatorHIDButtonEvent)
    /// Rotate the simulated device.
    case rotate(SimulatorOrientation)
    /// Rotate an Apple Watch Digital Crown by a raw delta.
    case digitalCrown(Double)
    /// Toggle the simulated software keyboard.
    case toggleSoftwareKeyboard
    /// Capture or release the Mac's physical input devices for iPadOS.
    case setHIDCapture(SimulatorHIDCaptureMode)
    /// Simulate a memory warning.
    case memoryWarning
    /// Toggle a Core Animation diagnostic.
    case coreAnimationDiagnostic(SimulatorCADiagnostic, enabled: Bool)
    /// Configure the experimental camera feed entirely inside the isolated worker.
    case configureCamera(requestID: UUID, configuration: SimulatorCameraConfiguration)
    /// Confirms the host recorded cleanup ownership for a resolved camera target.
    case acknowledgeCameraTarget(requestID: UUID)
    /// Replace the shared source without selecting or relaunching an application.
    case switchCameraSource(requestID: UUID, configuration: SimulatorCameraConfiguration)
    /// Hot-swap source-independent camera mirroring.
    case setCameraMirror(requestID: UUID, mode: SimulatorCameraMirrorMode)
    /// Request a correlated camera source, injection, and host-device snapshot.
    case requestCameraStatus(requestID: UUID)
    /// Suppress camera reinjection before an intentional app lifecycle change.
    case prepareApplicationMutation(requestID: UUID, bundleIdentifier: String)
    /// Apply one live private interface setting inside the selected Simulator.
    case setPrivateInterface(
        requestID: UUID,
        deviceID: String,
        setting: SimulatorInterfaceSetting
    )
    /// Request live private interface values from the selected Simulator.
    case requestPrivateInterfaceStatus(requestID: UUID, deviceID: String)
    /// Mutate a permission unavailable through public `simctl privacy`, with
    /// every private database and plist operation contained in the worker.
    case setPrivatePrivacy(
        requestID: UUID,
        deviceID: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundleIdentifier: String
    )
    /// Request a correlated TCC, location, and notification authorization snapshot.
    case requestPrivacy(requestID: UUID, deviceID: String, bundleIdentifier: String?)
    /// Reload the foreground React Native or Expo JavaScript bundle.
    case reloadReactNative(requestID: UUID)
    /// Show a correlated accessibility-node frame overlay, or clear it when
    /// both node and frame are `nil`.
    case setAccessibilityHighlight(requestID: UUID, nodeID: String?, frame: SimulatorRect?)
    /// Request a fresh accessibility tree.
    case requestAccessibility(UUID)
    /// Request metadata for the foreground application.
    case requestForegroundApplication(UUID)
    /// Discover inspectable Safari and `WKWebView` targets for the attached device.
    case requestWebInspectorTargets(requestID: UUID, deviceID: String)
    /// Select a target and open a worker-owned raw inspector session.
    case attachWebInspector(requestID: UUID, targetID: String)
    /// Release the selected target so Safari or another inspector can attach.
    case releaseWebInspector(requestID: UUID)
    /// Highlight or unhighlight the selected page's document root.
    case setWebInspectorHighlight(requestID: UUID, enabled: Bool)
    /// Send one raw JSON Web Inspector command to the selected page.
    case sendWebInspectorMessage(requestID: UUID, json: String)
    /// Release every touch and key held by the host session.
    case releaseInputs
    /// Intentionally terminate the renderer in DEBUG builds for diagnostics.
    case terminateRenderer
    /// Stop capture and exit cleanly.
    case shutdown
}

extension SimulatorWorkerInbound {
    /// Correlation identifier carried by request/response worker operations.
    public var requestIdentifier: UUID? {
        switch self {
        case let .typeText(requestID, _),
             let .interactiveAction(requestID, _),
             let .configureCamera(requestID, _),
             let .switchCameraSource(requestID, _),
             let .setCameraMirror(requestID, _),
             let .requestCameraStatus(requestID),
             let .prepareApplicationMutation(requestID, _),
             let .setPrivateInterface(requestID, _, _),
             let .requestPrivateInterfaceStatus(requestID, _),
             let .setPrivatePrivacy(requestID, _, _, _, _),
             let .requestPrivacy(requestID, _, _),
             let .reloadReactNative(requestID),
             let .setAccessibilityHighlight(requestID, _, _),
             let .requestAccessibility(requestID),
             let .requestForegroundApplication(requestID),
             let .requestWebInspectorTargets(requestID, _),
             let .attachWebInspector(requestID, _),
             let .releaseWebInspector(requestID),
             let .setWebInspectorHighlight(requestID, _),
             let .sendWebInspectorMessage(requestID, _):
            requestID
        default:
            nil
        }
    }
}
