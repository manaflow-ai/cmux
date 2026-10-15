public import Foundation

/// A capture device a page can ask for, for macOS's own (TCC) permission.
public enum BrowserMediaDevice: String, CaseIterable, Hashable, Sendable {
    case camera
    case microphone

    /// The device of a permission kind, if it is one.
    public init?(_ kind: BrowserPagePermissionRequest.Kind) {
        switch kind {
        case .camera: self = .camera
        case .microphone: self = .microphone
        default: return nil
        }
    }

    /// The System Settings pane where the person can give cmux this device
    /// (Privacy & Security > Camera / Microphone).
    public var systemSettingsURL: URL {
        switch self {
        case .camera: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        }
    }
}

/// macOS's answer for cmux and one capture device (`AVAuthorizationStatus`).
public enum BrowserMediaAuthorization: Equatable, Sendable {
    /// cmux may use the device.
    case authorized
    /// macOS has not asked yet; asking shows macOS's own prompt.
    case notDetermined
    /// The person turned the device off for cmux in System Settings.
    case denied
    /// The device is managed (MDM, parental controls): nobody here can allow it.
    case restricted
}

/// Reads and requests macOS's permission for cmux to use a capture device.
/// The app passes an `AVCaptureDevice` implementation; tests pass a fake, so
/// no test (or dogfood run) ever raises macOS's own prompt.
@MainActor
public protocol BrowserMediaAuthorizationProviding: AnyObject {
    /// The current status for a device.
    func authorization(for device: BrowserMediaDevice) -> BrowserMediaAuthorization
    /// Asks macOS (its own prompt) for a device whose status is ``BrowserMediaAuthorization/notDetermined``.
    /// - Returns: Whether macOS granted it.
    func requestAccess(for device: BrowserMediaDevice) async -> Bool
}

/// How macOS's permission shapes a camera/microphone question (design spec §4 v1.4).
public enum BrowserMediaAuthorizationGate: Equatable, Sendable {
    /// Every device is authorized or can still be asked for: show the normal question.
    /// `needsRequest` lists the devices macOS has not been asked about yet.
    case ask(needsRequest: [BrowserMediaDevice])
    /// A device is turned off for cmux: tell the person, offer System Settings, deny the page.
    case blocked([BrowserMediaDevice])
    /// A device is managed by the organization: tell the person, deny the page.
    case managed([BrowserMediaDevice])

    /// The gate for `devices` (in request order) under `authorization`.
    /// Managed wins over blocked (nothing the person can do), blocked over ask.
    public static func evaluate(
        _ devices: [BrowserMediaDevice],
        authorization: (BrowserMediaDevice) -> BrowserMediaAuthorization
    ) -> BrowserMediaAuthorizationGate {
        let statuses = devices.map { ($0, authorization($0)) }
        let managed = statuses.filter { $0.1 == .restricted }.map(\.0)
        if !managed.isEmpty { return .managed(managed) }
        let blocked = statuses.filter { $0.1 == .denied }.map(\.0)
        if !blocked.isEmpty { return .blocked(blocked) }
        return .ask(needsRequest: statuses.filter { $0.1 == .notDetermined }.map(\.0))
    }
}
