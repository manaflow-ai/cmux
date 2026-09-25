import Foundation

/// The address of something a Cloud machine serves: the machine itself, or one
/// workspace or terminal on it.
///
/// Cloud-served identifiers live in their own namespace so ownership is decided
/// by the identifier alone, never by live session state. That is what lets the
/// store's fences (input routing, repaint, Mac-lane suppression, foreground
/// switching) hold while a link is down, a machine is paused, or the app has
/// just relaunched. Demonstration content relies on the same rule.
///
/// The separator is the unit separator this repository already uses for
/// composite identifiers, and it cannot appear in a machine id or a daemon id,
/// so parsing back is unambiguous.
public struct CloudAddress: Hashable, Sendable {
    /// Marks every identifier in this namespace.
    public static let namespace = "cmux-cloud"
    private static let separator = "\u{1F}"

    /// The Cloud machine's stable id.
    public let machineID: String
    /// The daemon-side workspace or terminal id, or `nil` for the machine
    /// itself (the host its workspaces are contributed under).
    public let component: String?

    /// Addresses a machine, or something on it.
    public init(machineID: String, component: String? = nil) {
        self.machineID = machineID
        self.component = component
    }

    /// Reads an address back from an identifier in this namespace.
    ///
    /// Returns `nil` for anything outside the namespace, which is how a Mac's
    /// surface id is disowned.
    public init?(parsing identifier: String) {
        let prefix = Self.namespace + Self.separator
        guard identifier.hasPrefix(prefix) else { return nil }
        let body = identifier.dropFirst(prefix.count)
        guard !body.isEmpty else { return nil }
        // The component is everything after the machine id, so a daemon id
        // carrying the separator still round-trips.
        if let split = body.range(of: Self.separator) {
            let machineID = String(body[body.startIndex..<split.lowerBound])
            let component = String(body[split.upperBound...])
            guard !machineID.isEmpty, !component.isEmpty else { return nil }
            self.machineID = machineID
            self.component = component
        } else {
            machineID = String(body)
            component = nil
        }
    }

    /// The identifier this address renders to.
    public var identifier: String {
        guard let component else {
            return [Self.namespace, machineID].joined(separator: Self.separator)
        }
        return [Self.namespace, machineID, component].joined(separator: Self.separator)
    }

    /// The machine's own host address, dropping any component.
    public var host: CloudAddress { CloudAddress(machineID: machineID) }

    /// Whether the identifier belongs to this namespace at all.
    public static func owns(_ identifier: String) -> Bool {
        CloudAddress(parsing: identifier) != nil
    }
}
