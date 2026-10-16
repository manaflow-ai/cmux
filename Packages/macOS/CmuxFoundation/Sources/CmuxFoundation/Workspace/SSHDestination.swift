import Foundation

/// The parts of an SSH destination that identify the host.
struct SSHDestination: Equatable {
    let user: String?
    /// Host name, alias or IP address, without IPv6 brackets.
    let host: String
    let port: Int?

    init(user: String?, host: String, port: Int?) {
        self.user = user
        self.host = host
        self.port = port
    }

    init?(_ rawValue: String) {
        var rest = Substring(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        var allowsPort = false
        if rest.lowercased().hasPrefix("ssh://") {
            rest = rest.dropFirst("ssh://".count)
            if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
            allowsPort = true
        }

        // OpenSSH splits user and host at the last "@".
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            let userPart = rest[..<at]
            user = userPart.isEmpty ? nil : String(userPart)
            rest = rest[rest.index(after: at)...]
        }

        var port: Int?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let tail = rest[rest.index(after: close)...]
            if tail.hasPrefix(":") {
                port = Int(tail.dropFirst())
            }
            rest = rest[rest.index(after: rest.startIndex)..<close]
        } else if allowsPort,
                  let colon = rest.lastIndex(of: ":"),
                  rest.firstIndex(of: ":") == colon {
            // Only a URI carries a port after a single colon. A bare destination
            // like `host:2222` is not valid ssh syntax, and bare IPv6 has many colons.
            port = Int(rest[rest.index(after: colon)...])
            rest = rest[..<colon]
        }

        let host = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        self.init(user: user, host: host, port: port)
    }
}
