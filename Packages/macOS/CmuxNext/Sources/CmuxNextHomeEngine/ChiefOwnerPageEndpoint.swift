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
    /// What the Channels page gets from this owner.
    public enum PageEndpointOutcome: Sendable, Equatable {
        /// The owner's listener and a credential bound to the page.
        case ready(ChiefOwnerPageEndpoint)
        /// The owner is starting or reconnecting: the page tries again.
        case starting
        /// No owner endpoint (too old, refused, or never started): the page uses the build
        /// daemon only, as before, never a dead end.
        case unavailable
    }

    /// The page `page`'s endpoint on this owner. While the owner starts or reconnects the page
    /// waits for it (it would show the wrong conversations otherwise); a refusal or an owner
    /// that cannot start leaves the page on the build daemon.
    public func pageEndpoint(page: String) async -> PageEndpointOutcome {
        guard let connection else { return isRunning ? .starting : .unavailable }
        guard supports(DaemonCapability.wsListen.rawValue),
              supports(DaemonCapability.scopedPageCredential.rawValue) else { return .unavailable }
        do {
            // The owner's listener admits this page's Origin only (loopback, like the build daemon's).
            let listener = try await connection.request(WsListenRequest(allowOrigin: "cmux-page://cmux.\(page)"))
            let credential = try await connection.request(ScopedPageCredentialRequest(page: page))
            return .ready(ChiefOwnerPageEndpoint(url: listener.url, token: credential.credential))
        } catch let error as DaemonError where error.isLostConnection {
            return .starting
        } catch {
            return .unavailable
        }
    }
}
