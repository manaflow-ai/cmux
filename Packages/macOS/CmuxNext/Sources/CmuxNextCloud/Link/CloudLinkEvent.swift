import Foundation

/// The JSON lines cmux-tui helpers print on stdout.
package enum CloudLinkEvent: Equatable, Sendable {
    /// `wg hub --client-token`: `{"event":"hub-ready","socket":…,"routes":[…],"client_token":…}`.
    case hubReady(CloudHubEndpoint)
    /// `remote connect --headless --json`: the first
    /// `{"event":"connection-snapshot","local_socket":…}` names the local v12
    /// socket the app connects to like a local daemon.
    case connected(localSocket: String)
    case other

    package static func parse(_ line: String) -> CloudLinkEvent {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = object["event"] as? String else { return .other }
        switch event {
        case "hub-ready":
            guard let socket = object["socket"] as? String, !socket.isEmpty,
                  let token = object["client_token"] as? String, !token.isEmpty else { return .other }
            return .hubReady(CloudHubEndpoint(socket: socket, clientToken: token))
        case "connection-snapshot":
            guard let socket = object["local_socket"] as? String, !socket.isEmpty else { return .other }
            return .connected(localSocket: socket)
        default:
            return .other
        }
    }

    /// A later `connection-snapshot` of a running link: whether its
    /// `connection.state` is `connected` (false while it redials, after it
    /// gave up or closed); nil for any other line.
    package static func linkConnected(_ line: String) -> Bool? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["event"] as? String == "connection-snapshot",
              let state = (object["connection"] as? [String: Any])?["state"] as? String else { return nil }
        return state == "connected"
    }
}
