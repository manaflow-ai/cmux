import Foundation

/// A native Simulator tool action routed through ``SimulatorWorkerClient``.
public enum SimulatorControlAction: Equatable, Sendable {
    /// Execute a correlated native input or diagnostic action in the worker.
    case interactive(SimulatorInteractiveAction)
    /// List installed system and user applications.
    case listApplications(deviceID: String)
    /// Install an `.app` or `.ipa` at the supplied URL.
    case installApplication(deviceID: String, applicationURL: URL)
    /// Launch an installed application.
    case launchApplication(deviceID: String, bundleIdentifier: String, configuration: SimulatorLaunchConfiguration)
    /// Terminate a running application.
    case terminateApplication(deviceID: String, bundleIdentifier: String)
    /// Reconcile an injected camera target only while its durable owner remains current.
    case cleanupCameraApplication(deviceID: String, bundleIdentifier: String, ownershipToken: UUID)
    /// Open a URL through the simulated operating system.
    case openURL(deviceID: String, url: URL)
    /// Add photos, videos, Live Photo pairs, or contacts.
    case addMedia(deviceID: String, urls: [URL])
    /// Read plain text from the simulated pasteboard.
    case readClipboard(deviceID: String)
    /// Replace the simulated pasteboard with plain text.
    case writeClipboard(deviceID: String, text: String)
    /// Copy the host pasteboard onto the simulated pasteboard.
    case syncClipboardFromHost(deviceID: String)
    /// Set one fixed simulated location.
    case setLocation(deviceID: String, coordinate: SimulatorLocationCoordinate)
    /// Stop location simulation and clear its value.
    case clearLocation(deviceID: String)
    /// Start an interpolated location route.
    case startLocationRoute(deviceID: String, route: SimulatorLocationRoute)
    /// Deliver a JSON Apple Push Notification payload.
    case pushNotification(deviceID: String, bundleIdentifier: String, payloadURL: URL)
    /// Grant, revoke, or reset an application privacy service.
    case setPrivacy(
        deviceID: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundleIdentifier: String?
    )
    /// Read correlated TCC, location, and notification authorization status.
    case readPrivacy(deviceID: String, bundleIdentifier: String?)
    /// Merge values into the simulated status bar.
    case overrideStatusBar(deviceID: String, values: SimulatorStatusBarOverride)
    /// Clear every simulated status bar override.
    case clearStatusBar(deviceID: String)
    /// Change a public Simulator appearance or accessibility setting.
    case setInterface(deviceID: String, setting: SimulatorInterfaceSetting)
    /// Read live private interface settings through the contained helper.
    case readInterfaceStatus(deviceID: String)
    /// Save the current framebuffer to an image file.
    case screenshot(deviceID: String, destinationURL: URL, format: SimulatorScreenshotFormat)
    /// Return a cancellable long-running video command.
    case prepareVideoRecording(deviceID: String, destinationURL: URL, codec: SimulatorVideoCodec)
    /// Read a bounded interval from the simulated unified log.
    case recentLogs(deviceID: String, bundleIdentifier: String?, seconds: Double)
    /// Return a cancellable live unified-log command.
    case prepareLogStream(deviceID: String, bundleIdentifier: String?)
    /// Configure the experimental isolated-worker camera feed.
    case configureCamera(SimulatorCameraConfiguration)
    /// Hot-swap the source for every target in an existing camera session.
    case switchCameraSource(SimulatorCameraConfiguration)
    /// Change source-independent synthetic camera mirroring.
    case setCameraMirror(SimulatorCameraMirrorMode)
    /// Read camera source, injection, and host-device status.
    case readCameraStatus
    /// Reload the foreground React Native or Expo JavaScript bundle.
    case reloadReactNative
    /// Read a correlated, bounded accessibility snapshot from the worker.
    case readAccessibility
    /// Read correlated metadata for the current foreground application.
    case readForegroundApplication
    /// Show an accessibility-node frame overlay, or clear it with nil values.
    case setAccessibilityHighlight(nodeID: String?, frame: SimulatorRect?)
    /// Pause an active interpolated location route at its estimated position.
    case pauseLocationRoute(deviceID: String)
    /// Resume a route paused by cmux.
    case resumeLocationRoute(deviceID: String)
    /// Stop an active, paused, or completed route and restore its first waypoint.
    case stopLocationRoute(deviceID: String)
    /// Refresh Safari and `WKWebView` targets from the selected Simulator.
    case refreshWebInspectorTargets(deviceID: String)
    /// Attach a raw Web Inspector session to one target.
    case attachWebInspector(targetID: String)
    /// Release the currently attached Web Inspector target.
    case releaseWebInspector
    /// Highlight or unhighlight the attached page's root document.
    case setWebInspectorHighlight(enabled: Bool)
    /// Send one raw JSON command through the attached Web Inspector session.
    case sendWebInspectorMessage(json: String)
}
