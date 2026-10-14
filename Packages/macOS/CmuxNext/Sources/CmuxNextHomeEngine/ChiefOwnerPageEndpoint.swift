public import CmuxNextDaemon
public import Foundation

/// Where the Channels page reaches this build's Chief conversations: the
/// loopback page listener of this build's Chief home's conversation owner
/// (`ChiefHome` of this bundle, never another build's), with a credential
/// bound to that page (`page-credential {page}`, `page-credential-scoped-v1`).
///
/// The owner's app connection is a trusted local connection but not the
/// verified app, so it gets no person credential and no Cloud lease. The
/// scoped credential admits one handshake with the page's Origin only, so the
/// owner's page-router table applies to the page, and it is never the
/// person: Cloud conversations stay on the build's own daemon. The page asks
/// again on every reconnect (single use, 2 min).
public nonisolated struct ChiefOwnerPageEndpoint: Sendable, Equatable {
    public var url: String
    public var token: String

    public init(url: String, token: String) {
        self.url = url
        self.token = token
    }
}

extension ChiefConversationOwner {
    /// Why the owner has no page endpoint yet (the page tries again).
    public nonisolated struct NotConnected: Error, Sendable {}

    /// The page `page`'s endpoint on this owner; nil when the owner is too old
    /// for a scoped credential (the page then shows the build daemon's
    /// conversations only, as before). Throws `NotConnected` while the owner
    /// is starting or reconnecting, and the request's error on a lost
    /// connection, so the page waits for the owner instead of showing the
    /// wrong conversations.
    public func pageEndpoint(page: String) async throws -> ChiefOwnerPageEndpoint? {
        guard let connection else { throw NotConnected() }
        guard supports(DaemonCapabilities.shared.wsListen),
              supports(DaemonCapabilities.shared.scopedPageCredential) else { return nil }
        // The owner's listener admits this page's Origin only (loopback, like the build daemon's).
        let listener = try await connection.request(WsListenRequest(allowOrigin: "cmux-page://cmux.\(page)"))
        let credential = try await connection.request(ScopedPageCredentialRequest(page: page))
        return ChiefOwnerPageEndpoint(url: listener.url, token: credential.credential)
    }
}
