public import Foundation

/// This Mac's Tailscale address as `cmux host status --json` reports it: the first entry of
/// `addresses`, which the CLI prints as `100.x.y.z:port` (or `[fd7a:…]:port`).
public nonisolated struct ServerTailnetAddress: Sendable, Equatable {
    /// The address with its port, as other devices dial it.
    public var value: String

    /// - Parameter hostStatus: The stdout of `cmux host status --json`.
    /// - Returns: nil when the JSON is malformed or lists no address (Tailscale off, host not enabled).
    public init?(hostStatus: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: hostStatus) as? [String: Any],
              let addresses = root["addresses"] as? [Any],
              let first = addresses.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else { return nil }
        value = first
    }
}
