import Foundation

/// `remote-host-status` (`remote-host-v1`, docs/cmux-remote.md): cmux Remote's state as the
/// daemon sees it (never starts the host).
public struct RemoteHostStatusRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "remote-host-status"
    public static var requiredCapability: String? { DaemonCapability.remoteHost.rawValue }
    public init() {}
}

/// `remote-host-call {method, params}`: one cmux Remote request (status, refresh, request,
/// open_settings, restart, screen.share, screen.access, screen.stop_session).
public struct RemoteHostCallRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "remote-host-call"
    public static var requiredCapability: String? { DaemonCapability.remoteHost.rawValue }
    public var method: String
    public var params: JSONValue

    public init(method: String, params: JSONValue = .object([:])) {
        self.method = method
        self.params = params
    }
}

/// `remote-host-config`: the person's switches, from this verified app. Nil leaves one as it is.
/// `appPermissions` alone (no switch) only reports this app's own grants: the daemon keeps them in
/// memory for `remote-host-status` `app.permissions` and saves, starts and stops nothing.
public struct RemoteHostConfigRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "remote-host-config"
    public static var requiredCapability: String? { DaemonCapability.remoteHost.rawValue }
    public var computerUse: Bool?
    public var screenSharing: Bool?
    public var headless: Bool?
    public var appPermissions: AppPermissions?

    /// This app's own Screen Recording and Accessibility: the grants that matter in a build
    /// without cmux Remote (Release and NIGHTLY), where the app captures the screen itself.
    public struct AppPermissions: Encodable, Sendable, Equatable {
        public var screenRecording: Bool?
        public var accessibility: Bool?

        public init(screenRecording: Bool?, accessibility: Bool?) {
            self.screenRecording = screenRecording
            self.accessibility = accessibility
        }
    }

    public init(computerUse: Bool? = nil, screenSharing: Bool? = nil, headless: Bool? = nil,
                appPermissions: AppPermissions? = nil) {
        self.computerUse = computerUse
        self.screenSharing = screenSharing
        self.headless = headless
        self.appPermissions = appPermissions
    }
}
