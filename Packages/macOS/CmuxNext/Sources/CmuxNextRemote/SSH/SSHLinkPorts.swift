public import Foundation

/// One port the link forwards, as `port-forward` and `port-list` answer it (cmux-remote `link_ports.rs`
/// `LinkForward`): the machine's `port` on `host` is on this Mac's 127.0.0.1 at `localPort`.
public struct SSHLinkForward: Equatable, Sendable {
    public let port: Int
    public let host: String
    public let localPort: Int
    /// `http://127.0.0.1:<local_port>/`.
    public let url: String

    public init(port: Int, host: String, localPort: Int, url: String) {
        self.port = port
        self.host = host
        self.localPort = localPort
        self.url = url
    }

    /// Reads one `{"port","host","local_port","url"}` object; nil when a field is missing.
    init?(_ object: [String: Any]) {
        guard let port = object["port"] as? Int, let host = object["host"] as? String,
              let localPort = object["local_port"] as? Int, let url = object["url"] as? String else { return nil }
        self.init(port: port, host: host, localPort: localPort, url: url)
    }
}

/// A port request's answer: the value, or why the link refused or did not answer.
public enum SSHLinkPortAnswer<Value: Sendable>: Sendable {
    case success(Value)
    /// The link's reason (`{"ok":false,"error":…}`); `nil` when its socket did not answer at all.
    case failure(String?)

    /// The link's refusal reason, `nil` for a success or a socket that did not answer.
    public var reason: String? { if case .failure(let reason) = self { reason } else { nil } }
}

/// The port requests' wire format (cmux-remote `AdminRequest::PortForward`, `PortList`, `PortClose`): one JSON
/// line each, `method` in kebab-case, optional fields left out when nil.
public struct SSHLinkPortWire {
    public init() {}
    public static let listLine = #"{"method":"port-list"}"#

    public static func forwardLine(port: Int, host: String?, workspaceRoot: String?) -> String {
        line("port-forward", port: port, ["host": host, "workspace_root": workspaceRoot])
    }

    public static func closeLine(port: Int, host: String?) -> String {
        line("port-close", port: port, ["host": host])
    }

    /// Decodes an answer line: `{"ok":true,"result":{…}}` through `read`, `{"ok":false,"error":"…"}` as its reason.
    public static func decode<Value: Sendable>(_ line: Data?, _ read: ([String: Any]) -> Value?) -> SSHLinkPortAnswer<Value> {
        guard let line, let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return .failure(nil) }
        guard object["ok"] as? Bool == true else { return .failure(object["error"] as? String) }
        guard let result = object["result"] as? [String: Any], let value = read(result) else { return .failure(nil) }
        return .success(value)
    }

    private static func line(_ method: String, port: Int, _ optional: [String: String?]) -> String {
        var object: [String: Any] = ["method": method, "port": port]
        for (key, value) in optional { if let value, !value.isEmpty { object[key] = value } }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
