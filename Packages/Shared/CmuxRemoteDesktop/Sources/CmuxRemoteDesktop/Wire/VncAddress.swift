import CmuxMobileWire
import CmuxBrowserStream
import Foundation

/// A VNC server the Mac should dial: a hostname or IP literal and a port.
/// Never a URL: anything with a scheme, user info, path or whitespace is
/// refused on both ends, so the phone can only name an RFB endpoint.
public struct VncAddress: Hashable, Sendable {
    public static let defaultPort = 5900

    public var host: String
    public var port: Int
    /// A label for the UI ("Build VM").
    public var name: String?

    /// Validates `host` and `port`; throws for a URL, user info, a path or an
    /// out-of-range port. IPv6 literals may be bracketed.
    public init(host: String, port: Int = VncAddress.defaultPort, name: String? = nil) throws(RdWireError) {
        var host = host.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, host.utf8.count <= 253 else { throw RdWireError("vnc host: empty or too long") }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:_%")
        guard host.allSatisfy({ allowed.contains($0) }), !host.hasPrefix("-"), !host.hasPrefix(".") else {
            throw RdWireError("vnc host: only a hostname or an IP address")
        }
        guard (1...65535).contains(port) else { throw RdWireError("vnc port: out of range") }
        if let name, name.count > 64 { throw RdWireError("vnc name: too long") }
        self.host = host
        self.port = port
        self.name = name
    }

    /// True for loopback names and literals (`localhost`, 127.0.0.0/8, `::1`).
    public var isLoopback: Bool {
        let lower = host.lowercased()
        return lower == "localhost" || lower.hasSuffix(".localhost") || lower.hasPrefix("127.") || lower == "::1"
    }

    var jsonMembers: [String: JSONValue] {
        var out: [String: JSONValue] = ["host": .string(host), "port": .int(Int64(port))]
        if let name { out["name"] = .string(name) }
        return out
    }
}
