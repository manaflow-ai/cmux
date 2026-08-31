// Relay connect authentication (v2): the endpoint presents its OWN Stack
// access token on the WebSocket upgrade; the relay worker verifies it against
// the Stack API and derives the object name from the verified user id. There
// is no ticket and no web-app mint. The provider must return a token that is
// fresh by the caller's own auth stack (both platforms' providers refresh on
// demand), so a stale token here means the session is genuinely dying.

import CMUXMobileCore
import Foundation

/// The endpoint's current Stack access token. Throws when signed out.
public typealias RelayAccessTokenProvider = @Sendable () async throws -> String

public enum RelayConnectAuth {
    /// Connect headers for one dial. The worker deletes the token header
    /// before forwarding to the Durable Object. `instanceTag` is the target
    /// HOST build's app-instance tag (the host sends its own, a client sends
    /// its pairing's): tagged dev builds get their own relay object per
    /// (user, device, tag), so sibling dev builds on one Mac stop contending
    /// for the single host slot. Untagged values are omitted and land on the
    /// historical shared object.
    public static func headers(
        accessToken: String,
        role: RelayRole,
        hostDeviceID: String,
        deviceID: String,
        instanceTag: String? = nil
    ) -> [String: String] {
        var headers = [
            RelayProtocol.stackAccessHeaderName: accessToken,
            RelayProtocol.roleHeaderName: role.rawValue,
            RelayProtocol.hostDeviceHeaderName: hostDeviceID.lowercased(),
            RelayProtocol.deviceHeaderName: deviceID.lowercased(),
        ]
        if let tag = normalizedInstanceTag(instanceTag) {
            headers[RelayProtocol.instanceTagHeaderName] = tag
        }
        return headers
    }

    /// Normalizes an app-instance tag for the connect header: trimmed and
    /// lowercased, or nil when the tag does not name its own relay object
    /// (absent, blank, a release lane, or a value the worker would reject).
    /// Mirrors `parseInstanceTag` in workers/mobile-relay/src/protocol.ts,
    /// except an unusable value means "send nothing" here instead of a 400
    /// there, so an odd local launch tag degrades to today's shared object
    /// rather than failing the dial. Release lanes stay untagged because
    /// their two endpoints update asynchronously (App Store phone, auto-
    /// updated Mac) and must never disagree about the object name.
    public static func normalizedInstanceTag(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !tag.isEmpty,
              !RelayProtocol.untaggedInstanceTags.contains(tag),
              tag.count <= RelayProtocol.maxInstanceTagChars,
              tag.range(of: RelayProtocol.instanceTagPattern, options: .regularExpression) != nil
        else { return nil }
        return tag
    }

    /// The default production dial target; a Debug env override on either
    /// platform substitutes the dev worker.
    public static func defaultRelayURL() -> URL? {
        URL(string: RelayProtocol.defaultRelayURL)
    }

    /// The dev relay worker. Debug builds dial this by default because the
    /// production hostname is not deployed yet and Debug builds authenticate
    /// against the dev Stack project, which only the dev worker verifies.
    public static let debugDefaultRelayURLString =
        "wss://cmux-mobile-relay-dev.debussy.workers.dev/v1/connect"

    /// The one place a dial target is decided, with its provenance for
    /// diagnostics. Debug: `CMUX_MOBILE_RELAY_URL` env override, else the dev
    /// worker. Release: the generated production constant, always. Both
    /// platforms resolve through here so no launch path (home screen,
    /// launcher relaunch, `open`) can change which relay a build dials.
    public static func resolvedRelayURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (url: URL?, source: String) {
        #if DEBUG
        if let raw = environment["CMUX_MOBILE_RELAY_URL"], !raw.isEmpty {
            return (URL(string: raw), "env:CMUX_MOBILE_RELAY_URL")
        }
        return (URL(string: debugDefaultRelayURLString), "debug-default(dev worker)")
        #else
        _ = environment
        return (URL(string: RelayProtocol.defaultRelayURL), "production-default")
        #endif
    }

    /// The resolved relay origin's liveness endpoint, for the launch-time TLS
    /// pre-warm: same host and port as the wss dial target, https scheme
    /// (wss→https; the loopback-dev ws→http), fixed `/healthz` path, no query
    /// or fragment. The worker serves it unauthenticated.
    public static func healthzURL(forRelayURL relayURL: URL) -> URL? {
        guard var components = URLComponents(
            url: relayURL,
            resolvingAgainstBaseURL: false
        ), let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "wss", "https":
            components.scheme = "https"
        case "ws", "http":
            components.scheme = "http"
        default:
            return nil
        }
        components.path = "/healthz"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// Launch-time TLS pre-warm for the relay dial path.
///
/// One fire-and-forget HEAD to the resolved relay origin's `/healthz`, issued
/// on the SAME `URLSession` the relay WebSocket transport dials with, so DNS,
/// TCP, and the TLS session are already established in that session's
/// connection pool when the first `wss` dial starts. No retries, no error
/// surfacing, bounded timeout: a failed pre-warm costs nothing, the dial just
/// pays the ordinary handshake.
///
/// Privacy: the request carries NO token, cookie, or identifying header. It
/// reveals to the relay origin, which the app is about to dial anyway, only
/// that an app instance launched.
public enum RelayTLSPrewarm {
    /// Fires the pre-warm and returns the URL it hit (nil when the relay URL
    /// cannot be resolved; nothing is sent then).
    @discardableResult
    public static func fire(
        urlSession: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let relayURL = RelayConnectAuth.resolvedRelayURL(
            environment: environment
        ).url, let healthzURL = RelayConnectAuth.healthzURL(forRelayURL: relayURL) else {
            return nil
        }
        var request = URLRequest(url: healthzURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        // A plain (completion-less) task: the response and any error are
        // deliberately dropped.
        urlSession.dataTask(with: request).resume()
        return healthzURL
    }
}

/// The host admits each client session END TO END: the client's first frame
/// on the RPC channel is this request, carrying the same Stack token, and the
/// host verifies it itself (the relay chain is not trusted with data-plane
/// authority). The client sends it fire-and-forget: a rejected admission ends
/// with the host closing the session, which surfaces as EOF and drives the
/// normal repair path. The response id is unknown to the RPC session and is
/// dropped by its dispatch.
public enum RelayAdmission {
    public static let method = "mobile.session.admit"
    public static let requestID = "relay-admit-1"

    /// The admission request as one length-prefixed sync frame, ready to be
    /// the first bytes on a client session's RPC stream.
    public static func admitFrame(accessToken: String, deviceID: String) throws -> Data {
        let envelope: [String: Any] = [
            "id": requestID,
            "method": method,
            "params": ["device_id": deviceID.lowercased()],
            "auth": ["stack_access_token": accessToken],
        ]
        let json = try JSONSerialization.data(withJSONObject: envelope)
        return try MobileSyncFrameCodec.encodeFrame(json)
    }
}
