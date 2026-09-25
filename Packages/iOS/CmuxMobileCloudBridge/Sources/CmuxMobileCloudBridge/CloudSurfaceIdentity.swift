import Foundation

/// The identifier namespace for Cloud-served workspaces and terminals.
///
/// Ownership of a surface is decided by this namespace rather than by live
/// session state, so the store's fences (input routing, replay, lane
/// suppression) hold while a link is down, a machine is paused, or the app is
/// relaunched. The same rule the demonstration content path relies on.
///
/// The unit separator is the separator this repository already uses for
/// composite identifiers, and it cannot appear in a machine id or a daemon
/// terminal id, so parsing back is unambiguous.
public enum CloudSurfaceIdentity: Sendable {
    /// Marks every identifier this namespace owns.
    public static let prefix = "cmux-cloud"
    static let separator = "\u{1F}"

    /// The surface id for one terminal on one machine.
    public static func surfaceID(machineID: String, terminalID: String) -> String {
        [prefix, machineID, terminalID].joined(separator: separator)
    }

    /// The workspace row id for one remote workspace on one machine.
    public static func workspaceID(machineID: String, remoteWorkspaceID: String) -> String {
        [prefix, machineID, remoteWorkspaceID].joined(separator: separator)
    }

    /// The synthetic host id a machine contributes its workspaces under.
    public static func hostID(machineID: String) -> String {
        [prefix, machineID].joined(separator: separator)
    }

    /// Whether the identifier belongs to this namespace.
    public static func owns(_ identifier: String) -> Bool {
        identifier.hasPrefix(prefix + separator)
    }

    /// The machine and trailing component of a namespaced identifier.
    ///
    /// The trailing component is everything after the machine id, so a daemon
    /// id containing the separator would still round-trip.
    public static func parse(_ identifier: String) -> (machineID: String, remainder: String)? {
        guard owns(identifier) else { return nil }
        let body = identifier.dropFirst(prefix.count + separator.count)
        guard let split = body.range(of: separator) else { return nil }
        let machineID = String(body[body.startIndex..<split.lowerBound])
        let remainder = String(body[split.upperBound...])
        guard !machineID.isEmpty, !remainder.isEmpty else { return nil }
        return (machineID, remainder)
    }

    /// The machine id a namespaced host identifier names.
    public static func machineID(fromHostID hostID: String) -> String? {
        guard owns(hostID) else { return nil }
        let machineID = String(hostID.dropFirst(prefix.count + separator.count))
        return machineID.isEmpty ? nil : machineID
    }
}
