public import Foundation

/// A client for the mobile push API: register, remove, and test push tokens.
@MainActor
public final class MobilePushRouteClient {
    private let transport: MobileAuthenticatedRouteTransport

    /// Creates a push route client over an authenticated transport.
    ///
    /// - Parameters:
    ///   - baseURL: The mobile API base URL.
    ///   - session: The URL session used to perform requests. Defaults to `.shared`.
    ///   - tokenProvider: The auth seam supplying bearer tokens and authentication state.
    public init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenProvider: any AuthTokenProviding
    ) {
        self.transport = MobileAuthenticatedRouteTransport(
            baseURL: baseURL,
            session: session,
            tokenProvider: tokenProvider
        )
    }

    /// Whether a user is currently authenticated.
    public var isAuthenticated: Bool {
        transport.isAuthenticated
    }

    /// Registers or upserts an APNs push token with the mobile API.
    ///
    /// - Parameters:
    ///   - token: The APNs device token, hex-encoded.
    ///   - environment: The APNs environment the token belongs to.
    ///   - platform: The client platform, for example `ios`.
    ///   - bundleId: The app bundle identifier the token was issued for.
    ///   - deviceId: An optional stable device identifier.
    /// - Throws: A transport or networking error.
    public func upsertPushToken(
        token: String,
        environment: MobilePushEnvironment,
        platform: String,
        bundleId: String,
        deviceId: String?
    ) async throws {
        _ = try await transport.send(
            path: "api/mobile/push/register",
            body: MobilePushRegisterRequest(
                token: token,
                environment: environment,
                platform: platform,
                bundleId: bundleId,
                deviceId: deviceId
            ),
            responseType: MobileOKResponse.self
        )
    }

    /// Removes a previously registered APNs push token.
    ///
    /// - Parameter token: The APNs device token to remove, hex-encoded.
    /// - Throws: A transport or networking error.
    public func removePushToken(token: String) async throws {
        _ = try await transport.send(
            path: "api/mobile/push/remove",
            body: MobilePushRemoveRequest(token: token),
            responseType: MobileOKResponse.self
        )
    }

    /// Sends a test push notification to the current user.
    ///
    /// - Parameters:
    ///   - title: The notification title.
    ///   - body: The notification body text.
    /// - Returns: The server's report of how many notifications were scheduled.
    /// - Throws: A transport or networking error.
    public func sendTestPush(title: String, body: String) async throws -> MobilePushTestResponse {
        try await transport.send(
            path: "api/mobile/push/test",
            body: MobilePushTestRequest(title: title, body: body),
            responseType: MobilePushTestResponse.self
        )
    }
}
