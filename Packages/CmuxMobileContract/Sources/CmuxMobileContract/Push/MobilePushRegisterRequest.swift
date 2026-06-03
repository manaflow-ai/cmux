import Foundation

/// The request body to register or upsert an APNs push token with the mobile API.
public struct MobilePushRegisterRequest: Encodable, Equatable, Sendable {
    /// The APNs device token, hex-encoded.
    public let token: String

    /// The APNs environment the token belongs to.
    public let environment: MobilePushEnvironment

    /// The client platform, for example `ios`.
    public let platform: String

    /// The app bundle identifier the token was issued for.
    public let bundleId: String

    /// An optional stable device identifier.
    public let deviceId: String?

    /// Creates a push registration request.
    ///
    /// - Parameters:
    ///   - token: The APNs device token, hex-encoded.
    ///   - environment: The APNs environment the token belongs to.
    ///   - platform: The client platform, for example `ios`.
    ///   - bundleId: The app bundle identifier the token was issued for.
    ///   - deviceId: An optional stable device identifier.
    public init(
        token: String,
        environment: MobilePushEnvironment,
        platform: String,
        bundleId: String,
        deviceId: String?
    ) {
        self.token = token
        self.environment = environment
        self.platform = platform
        self.bundleId = bundleId
        self.deviceId = deviceId
    }
}
