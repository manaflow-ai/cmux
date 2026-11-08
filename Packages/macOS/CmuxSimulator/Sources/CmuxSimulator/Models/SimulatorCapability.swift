/// A capability negotiated with the active Xcode and Simulator runtime.
public enum SimulatorCapability: String, Codable, CaseIterable, Hashable, Sendable {
    /// Direct headless framebuffer capture.
    case framebuffer
    /// Single-finger touch injection.
    case touch
    /// Two-finger touch injection.
    case multiTouch
    /// USB HID keyboard injection.
    case keyboard
    /// Native macOS pointer and keyboard capture for iPadOS.
    case hostInputCapture
    /// Hardware-button injection.
    case hardwareButtons
    /// Device orientation injection.
    case rotation
    /// Apple Watch Digital Crown injection.
    case digitalCrown
    /// Simulator memory warnings.
    case memoryWarning
    /// Core Animation diagnostics.
    case coreAnimationDiagnostics
    /// Accessibility-tree inspection.
    case accessibility
    /// Foreground-application inspection.
    case foregroundApplication
    /// Simulator appearance and accessibility settings.
    case userInterfaceSettings
    /// Synthetic camera injection.
    case cameraInjection
    /// Extended privacy-permission control.
    case extendedPermissions
    /// Raw Safari and `WKWebView` inspection through the Simulator's WIR socket.
    case webInspector
    /// Apple DeviceKit chrome and button geometry.
    case deviceChrome
}
