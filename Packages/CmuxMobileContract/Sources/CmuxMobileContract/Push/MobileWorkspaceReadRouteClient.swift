public import Foundation

/// A client for the mobile workspace mark-read API.
///
/// This client takes primitive arguments rather than an inbox item so it stays free of any
/// terminal or inbox domain type. The app maps a domain item to these primitives before calling.
@MainActor
public final class MobileWorkspaceReadRouteClient {
    private let transport: MobileAuthenticatedRouteTransport

    /// Creates a workspace mark-read client over an authenticated transport.
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

    /// Marks a workspace as read up to a given event sequence.
    ///
    /// - Parameters:
    ///   - teamID: The team slug or identifier the workspace belongs to.
    ///   - workspaceID: The workspace identifier to mark read.
    ///   - latestEventSeq: The latest event sequence read, or `nil` to mark fully read.
    /// - Throws: A transport or networking error.
    public func markRead(
        teamID: String,
        workspaceID: String,
        latestEventSeq: Int?
    ) async throws {
        _ = try await transport.send(
            path: "api/mobile/workspaces/mark-read",
            body: MobileMarkReadRequest(
                teamSlugOrId: teamID,
                workspaceId: workspaceID,
                latestEventSeq: latestEventSeq
            ),
            responseType: MobileOKResponse.self
        )
    }
}
