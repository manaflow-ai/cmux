import Foundation

/// `helper-status` (`helper-v1`, docs/cmux-helper.md): cmux Helper's grants and name as this app
/// last reported them (`permissions`, `name`) and, for this verified app, the Computer Use worker's status.
public struct HelperStatusRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "helper-status"
    public static var requiredCapability: String? { DaemonCapability.helper.rawValue }
    public init() {}
}

/// `helper-config {permissions, name}`: cmux Helper's grants and System Settings name, as this
/// verified app read them from the helper. The daemon keeps them in memory for `helper-status` and
/// saves, starts and stops nothing.
public struct HelperConfigRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "helper-config"
    public static var requiredCapability: String? { DaemonCapability.helper.rawValue }
    public var permissions: Permissions?
    public var name: String?

    /// cmux Helper's Screen Recording and Accessibility.
    public struct Permissions: Encodable, Sendable, Equatable {
        public var screenRecording: Bool?
        public var accessibility: Bool?

        public init(screenRecording: Bool?, accessibility: Bool?) {
            self.screenRecording = screenRecording
            self.accessibility = accessibility
        }
    }

    public init(permissions: Permissions? = nil, name: String? = nil) {
        self.permissions = permissions
        self.name = name
    }
}

/// `computer-use-config {config}`: the person's Computer Use policy (`PolicyConfig` JSON), from this
/// verified app. The daemon's Computer Use worker runs with it (on macOS in cmux Helper).
public struct ComputerUseConfigRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "computer-use-config"
    public static var requiredCapability: String? { DaemonCapability.computerUse.rawValue }
    public var config: JSONValue

    public init(config: JSONValue) {
        self.config = config
    }
}

/// `computer-use-approvals {action, app_id?}`: list, forget, always, never or revoke_sessions.
public struct ComputerUseApprovalsRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "computer-use-approvals"
    public static var requiredCapability: String? { DaemonCapability.computerUse.rawValue }
    public var action: String
    public var appID: String?

    enum CodingKeys: String, CodingKey {
        case action
        case appID = "app_id"
    }

    public init(action: String, appID: String? = nil) {
        self.action = action
        self.appID = appID
    }
}
