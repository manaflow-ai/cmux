/// How `WireHomeSource` proves who the user is to a `cmux.wire/1` server.
public enum HomeWireAuth: Sendable {
    /// The hosted cmux cloud: every request and socket carries
    /// `Authorization: Bearer <Stack access token>`. A 401 or a 4401 socket
    /// close asks the provider for a fresh token once.
    case stack(any HomeBearerProviding)
    /// A self-hosted server over Tailscale: no `Authorization` header at all.
    /// The server identifies the caller by its tailnet address (WhoIs), and
    /// the client learns its own user id from `GET /v1/selfhost/info`.
    case tailscale
}
