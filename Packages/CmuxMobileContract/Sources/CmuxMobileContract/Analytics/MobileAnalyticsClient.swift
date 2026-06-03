public import Foundation
import OSLog

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "mobile.analytics")

private struct MobileAnalyticsCaptureRequest: Encodable, Equatable, Sendable {
    let event: MobileAnalyticsEventName
    let properties: MobileAnalyticsProperties
}

/// Captures mobile analytics events by POSTing them to the mobile API.
///
/// Capture is fire-and-forget: ``capture(event:properties:)`` returns immediately and the request
/// runs in a detached task; failures are logged, not surfaced. Events are dropped when the user is
/// not authenticated.
@MainActor
public final class MobileAnalyticsClient: MobileAnalyticsTracking {
    private let transport: MobileAuthenticatedRouteTransport
    private let platform: String
    private let bundleId: String?

    /// Creates an analytics client over an authenticated transport.
    ///
    /// - Parameters:
    ///   - baseURL: The mobile API base URL.
    ///   - session: The URL session used to perform requests. Defaults to `.shared`.
    ///   - tokenProvider: The auth seam supplying bearer tokens and authentication state.
    ///   - platform: The client platform reported with each event. Defaults to `ios`.
    ///   - bundleId: The bundle id reported with each event, or `nil`.
    public init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenProvider: any AuthTokenProviding,
        platform: String = "ios",
        bundleId: String?
    ) {
        self.transport = MobileAuthenticatedRouteTransport(
            baseURL: baseURL,
            session: session,
            tokenProvider: tokenProvider
        )
        self.platform = platform
        self.bundleId = bundleId
    }

    public func capture(event: MobileAnalyticsEventName, properties: MobileAnalyticsProperties) {
        guard transport.isAuthenticated else { return }
        let payload = MobileAnalyticsCaptureRequest(
            event: event,
            properties: properties.withDefaults(platform: platform, bundleId: bundleId)
        )

        Task {
            do {
                _ = try await transport.send(
                    path: "api/mobile/analytics",
                    body: payload,
                    responseType: MobileAcceptedResponse.self
                )
            } catch {
                log.error("Failed to capture \(event.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
