import Foundation

/// `helper-host-status` (`helper-host-v1`, docs/computer-use-helper.md): cmux Computer Use's state as the
/// daemon sees it (never starts the host).
public struct HelperHostStatusRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "helper-host-status"
    public static var requiredCapability: String? { DaemonCapability.helperHost.rawValue }
    public init() {}
}

/// `helper-host-call {method, params}`: one cmux Computer Use request (status, refresh, request,
/// open_settings, restart, screen.share, screen.access, screen.stop_session).
public struct HelperHostCallRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "helper-host-call"
    public static var requiredCapability: String? { DaemonCapability.helperHost.rawValue }
    public var method: String
    public var params: JSONValue

    public init(method: String, params: JSONValue = .object([:])) {
        self.method = method
        self.params = params
    }
}

/// `helper-host-config`: the person's switches, from this verified app. Nil leaves one as it is.
public struct HelperHostConfigRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "helper-host-config"
    public static var requiredCapability: String? { DaemonCapability.helperHost.rawValue }
    public var computerUse: Bool?
    public var screenSharing: Bool?
    public var headless: Bool?

    public init(computerUse: Bool? = nil, screenSharing: Bool? = nil, headless: Bool? = nil) {
        self.computerUse = computerUse
        self.screenSharing = screenSharing
        self.headless = headless
    }
}
