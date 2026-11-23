import Foundation

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
