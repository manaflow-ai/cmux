import Foundation

/// Errors surfaced by the `cmux remotes` flow.
enum RemotesClientError: Error, CustomStringConvertible, Equatable {
    case notSignedIn
    case sessionRefreshFailed
    case invalidRoute(String)
    case loopbackRoute(host: String)
    case notAttachable(host: String)
    case noRoutes
    case emptyName
    case notFound(String)
    case httpStatus(Int, String)
    case malformedResponse(String)
    case backendUnreachable(url: String, detail: String)
    case tailscaleStatusUnavailable
    case tailscalePeerNotFound(host: String)
    case tailscalePeerAmbiguous(host: String)
    case tailscalePeerInvalid(host: String)

    var description: String {
        switch self {
        case .notSignedIn:
            return "Not signed in. Run `cmux auth login`, then retry."
        case .sessionRefreshFailed:
            return "Signed in, but cmux could not refresh your session (network or server issue). Retry in a moment."
        case let .invalidRoute(value):
            return "Invalid route '\(value)'. Use host:port, e.g. 100.64.1.2:51001 or my-mac.tailnet.ts.net:51001."
        case let .loopbackRoute(host):
            return """
                Refusing to add a loopback remote (\(host)). A phone that dials localhost / 127.0.0.1 / ::1 dials \
                itself, so the remote would never be reachable. Use the Mac's Tailscale address instead.
                """
        case let .notAttachable(host):
            return """
                '\(host)' is not attachable from the iOS app. A signed-in phone can only authenticate to a \
                registry route over Tailscale, so the stored host must be a numeric Tailscale IPv4 or IPv6 peer \
                address. A plain LAN IP or hostname would show in the device list but fail to connect.
                """
        case .noRoutes:
            return "At least one --route host:port is required. Example: cmux remotes add my-mac --route 100.64.1.2:51001"
        case .emptyName:
            return "A non-empty remote name is required. Example: cmux remotes add my-mac --route 100.64.1.2:51001"
        case let .notFound(target):
            return "No remote matching '\(target)'. Run `cmux remotes list` to see registered remotes."
        case let .httpStatus(status, body):
            return RemotesClient.formatHTTPError(status: status, body: body)
        case let .malformedResponse(message):
            return "The device registry returned an unexpected response: \(message)"
        case let .backendUnreachable(url, detail):
            return "Could not reach the cmux backend at \(url): \(detail)"
        case .tailscaleStatusUnavailable:
            return "Could not read the local Tailscale peer map. Start Tailscale, sign in, and retry."
        case let .tailscalePeerNotFound(host):
            return "Tailscale has no peer whose exact MagicDNS name is '\(host)'. Check `tailscale status`, then retry."
        case let .tailscalePeerAmbiguous(host):
            return "Tailscale reported more than one peer for '\(host)'. Refusing to choose a transport target."
        case let .tailscalePeerInvalid(host):
            return "Tailscale's peer record for '\(host)' did not contain only numeric Tailscale peer addresses."
        }
    }
}
