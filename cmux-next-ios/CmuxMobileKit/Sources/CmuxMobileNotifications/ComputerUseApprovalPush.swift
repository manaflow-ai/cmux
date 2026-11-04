import Foundation
import UserNotifications

/// A Computer Use question's push from the device hub (docs/device-hub/PROTOCOL.md,
/// "Computer Use approvals", Phone push): `userInfo["cmuxComputerUse"]`. It only
/// names the approval and the hub that holds it; the app fetches the approval
/// from that hub (only the one it is built with) and never acts on the push's text.
public struct ComputerUseApprovalNotice: Equatable, Sendable {
    public static let userInfoKey = "cmuxComputerUse"

    public var version: Int
    public var approvalID: String
    /// The asking machine's device id.
    public var deviceID: String
    /// The hub's public origin.
    public var hub: URL
    public var allowAlways: Bool
    public var answerableUntil: Date?

    public init(version: Int = 1, approvalID: String, deviceID: String, hub: URL, allowAlways: Bool = false, answerableUntil: Date? = nil) {
        self.version = version
        self.approvalID = approvalID
        self.deviceID = deviceID
        self.hub = hub
        self.allowAlways = allowAlways
        self.answerableUntil = answerableUntil
    }

    /// Reads `userInfo["cmuxComputerUse"]`; nil when it is missing, of another version or malformed.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let object = userInfo[Self.userInfoKey] as? [String: Any],
              let version = (object["v"] as? NSNumber)?.intValue, version == 1,
              let approvalID = object["approvalId"] as? String, !approvalID.isEmpty, approvalID.count <= 128,
              let deviceID = object["deviceId"] as? String, !deviceID.isEmpty,
              let hubText = object["hub"] as? String, let hub = URL(string: hubText),
              hub.scheme == "https" || hub.scheme == "http", hub.host() != nil else { return nil }
        self.version = version
        self.approvalID = approvalID
        self.deviceID = deviceID
        self.hub = hub
        allowAlways = (object["allowAlways"] as? Bool) ?? false
        answerableUntil = (object["answerableUntil"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    /// Whether the push names `configured` (the hub this build talks to): scheme, host and port.
    /// A push naming any other hub is ignored.
    public func isFrom(_ configured: URL) -> Bool {
        Self.origin(hub) == Self.origin(configured)
    }

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(port)"
    }

    /// The notification's request identifier: APNs uses the push's `apns-collapse-id`, `cu-<id>`.
    public var notificationIdentifier: String { Self.notificationIdentifier(approvalID: approvalID) }

    public static func notificationIdentifier(approvalID: String) -> String { "cu-\(approvalID)" }
}

/// The buttons of a Computer Use question, the same identifiers for both categories:
/// `CMUX_COMPUTER_USE_APPROVAL` (the device hub) and `CMUX_MOBILE_COMPUTER_USE` (a Mac's
/// cmux app through its iPhone host; docs/computer-use-approvals.md, "Phone wire (macOS)").
/// Every Allow opens the app, which shows the request and asks for Face ID before
/// signing; Deny sends a refusal without opening it (the phone must be unlocked).
/// "Always Allow <App>" is never a static button: it is in the app's sheet, behind
/// Face ID, when the asking machine allows it; a `cmux.cu.always` that does arrive
/// opens the app the same way.
public enum ComputerUseApprovalAction: String, CaseIterable, Sendable {
    case allowOnce = "cmux.cu.once"
    case allowSession = "cmux.cu.session"
    case allowAlways = "cmux.cu.always"
    case deny = "cmux.cu.deny"

    public var identifier: String { rawValue }

    public init?(identifier: String) {
        self.init(rawValue: identifier)
    }

    /// The buttons a Computer Use notification carries.
    public static let notificationButtons: [ComputerUseApprovalAction] = [.allowOnce, .allowSession, .deny]

    public var title: String {
        switch self {
        case .allowOnce: String(localized: "Allow Once")
        case .allowSession: String(localized: "Allow for This Session")
        case .allowAlways: String(localized: "Always Allow")
        case .deny: String(localized: "Deny")
        }
    }

    /// Whether the button opens the app: every Allow; Deny too when Settings → Require Face ID is on.
    public func opensApp(requireFaceID: Bool) -> Bool {
        switch self {
        case .allowOnce, .allowSession, .allowAlways: true
        case .deny: requireFaceID
        }
    }

    public func notificationAction(requireFaceID: Bool) -> UNNotificationAction {
        var options: UNNotificationActionOptions = [.authenticationRequired]
        if opensApp(requireFaceID: requireFaceID) { options.insert(.foreground) }
        if self == .deny { options.insert(.destructive) }
        return UNNotificationAction(identifier: identifier, title: title, options: options)
    }
}
