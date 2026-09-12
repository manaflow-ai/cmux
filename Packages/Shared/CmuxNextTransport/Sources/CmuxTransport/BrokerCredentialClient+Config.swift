import Foundation

extension BrokerCredentialClient {
    /// Password-authenticated broker configuration for isolated development harnesses.
    public struct Config: Sendable, Decodable {
        /// Final broker origin; authenticated requests never follow redirects.
        public var baseUrl: String
        /// Stack Auth deployment used to sign in the harness account.
        public var stackBase: String
        /// Stack Auth project that owns the account.
        public var stackProjectId: String
        /// Publishable Stack client key, not a server secret.
        public var stackPck: String
        /// Harness account email; never include this configuration in diagnostics.
        public var email: String
        /// Harness account password; keep this value out of logs and UI.
        public var password: String
        /// Stable device identifier registered with the broker.
        public var deviceId: String
        /// App-instance identifier registered with the broker.
        public var appInstanceId: String
        /// Build tag used to scope the registration.
        public var tag: String
        /// Platform label supplied with the registration.
        public var platform: String

        /// Creates an explicit harness configuration without ambient credentials.
        ///
        /// - Parameters:
        ///   - baseUrl: Final broker origin, without redirects.
        ///   - stackBase: Stack Auth deployment origin.
        ///   - stackProjectId: Project containing the harness account.
        ///   - stackPck: Publishable client key for that project.
        ///   - email: Harness account email.
        ///   - password: Harness account password.
        ///   - deviceId: Stable device registration identifier.
        ///   - appInstanceId: App-instance registration identifier.
        ///   - tag: Build tag for the registration.
        ///   - platform: Registration platform label.
        public init(
            baseUrl: String, stackBase: String, stackProjectId: String,
            stackPck: String, email: String, password: String,
            deviceId: String, appInstanceId: String, tag: String, platform: String
        ) {
            self.baseUrl = baseUrl
            self.stackBase = stackBase
            self.stackProjectId = stackProjectId
            self.stackPck = stackPck
            self.email = email
            self.password = password
            self.deviceId = deviceId
            self.appInstanceId = appInstanceId
            self.tag = tag
            self.platform = platform
        }
    }
}
