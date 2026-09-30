import Foundation

/// The JSON lines cmux-tui helpers print on stdout.
package enum CloudLinkEvent: Equatable, Sendable {
    /// `wg hub`: `{"event":"hub-ready","socket":…,"routes":[…]}`.
    case hubReady(socket: String)
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
            guard let socket = object["socket"] as? String, !socket.isEmpty else { return .other }
            return .hubReady(socket: socket)
        case "connection-snapshot":
            guard let socket = object["local_socket"] as? String, !socket.isEmpty else { return .other }
            return .connected(localSocket: socket)
        default:
            return .other
        }
    }
}
