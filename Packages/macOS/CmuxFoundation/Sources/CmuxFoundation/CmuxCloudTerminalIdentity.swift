import Foundation

/// A terminal key resolved from a catalog row for one Cloud machine.
///
/// ```swift
/// let identity = CmuxCloudTerminalIdentity(
///     catalogResource: ["id": "vm-one/terminal/term-real", "key": "stale"],
///     machine: "vm-one"
/// )
/// // identity?.key is "term-real".
/// ```
public struct CmuxCloudTerminalIdentity: Sendable, Equatable {
    /// The daemon terminal key, without a machine or resource-kind prefix.
    public let key: String

    /// Resolves canonical identity before considering legacy catalog fields.
    ///
    /// A full resource ID is authoritative even when its separate `key` field is
    /// stale. IDs for another machine or resource kind fail closed. Older rows
    /// may supply only a `key` or an unqualified terminal ID.
    ///
    /// - Parameters:
    ///   - catalogResource: The terminal catalog row to resolve.
    ///   - machine: The machine whose daemon will receive the key.
    public init?(catalogResource: [String: Any], machine: String) {
        guard !machine.isEmpty else { return nil }
        let id = (catalogResource["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, id.contains("/") {
            let prefix = "\(machine)/terminal/"
            guard id.hasPrefix(prefix) else { return nil }
            let key = String(id.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains("/") else { return nil }
            self.key = key
            return
        }
        if let key = (catalogResource["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty, !key.contains("/") {
            self.key = key
            return
        }
        guard let id, !id.isEmpty else { return nil }
        key = id
    }
}
