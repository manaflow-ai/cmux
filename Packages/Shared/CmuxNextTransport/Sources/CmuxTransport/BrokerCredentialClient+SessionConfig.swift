import Foundation

extension BrokerCredentialClient {
    /// Session-mode target: the broker origin plus this endpoint's
    /// registration coordinates. No Stack fields by design — the session
    /// token provider owns authentication.
    public struct SessionConfig: Sendable {
        /// Final broker origin; authenticated requests never follow redirects.
        public var baseUrl: String
        /// Stable device identifier registered with the broker.
        public var deviceId: String
        /// App-instance identifier registered with the broker.
        public var appInstanceId: String
        /// Build tag used to scope the registration.
        public var tag: String
        /// Platform label supplied with the registration.
        public var platform: String

        /// Creates registration coordinates for an injected signed-in session.
        ///
        /// - Parameters:
        ///   - baseUrl: Final broker origin, without redirects.
        ///   - deviceId: Stable device registration identifier.
        ///   - appInstanceId: App-instance registration identifier.
        ///   - tag: Build tag for the registration.
        ///   - platform: Registration platform label.
        public init(
            baseUrl: String, deviceId: String, appInstanceId: String,
            tag: String, platform: String
        ) {
            self.baseUrl = baseUrl
            self.deviceId = deviceId
            self.appInstanceId = appInstanceId
            self.tag = tag
            self.platform = platform
        }
    }
}
