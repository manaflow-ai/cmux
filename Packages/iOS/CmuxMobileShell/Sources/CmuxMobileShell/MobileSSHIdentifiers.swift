import Foundation

/// Identifier namespace for SSH computers.
///
/// SSH hosts ride the shell's ordinary per-computer stores (like the
/// demonstration computer), so every id they mint must be distinguishable
/// from a Mac's without consulting live session state:
///
/// - computer (`macDeviceID`): `cmux-ssh-<host uuid>`
/// - workspace row / terminal surface: `cmux-ssh-<host uuid>~<local id>`
///
/// The `~` separator never appears in a UUID, so the host id parses back
/// unambiguously.
enum MobileSSHIdentifiers {
    static let prefix = "cmux-ssh-"
    private static let separator: Character = "~"

    static func computerID(host: UUID) -> String {
        prefix + host.uuidString.lowercased()
    }

    static func scopedID(host: UUID, local: String) -> String {
        computerID(host: host) + String(separator) + local
    }

    /// Whether `identifier` belongs to any SSH computer.
    static func owns(_ identifier: String) -> Bool {
        identifier.hasPrefix(prefix)
    }

    /// Whether `identifier` is a well-formed workspace or surface id
    /// (`cmux-ssh-<host uuid>~<local id>`). Aggregated row ids that merely
    /// start with the prefix are not.
    static func isScopedID(_ identifier: String) -> Bool {
        hostID(of: identifier) != nil && localID(of: identifier) != nil
    }

    /// The host that owns a computer, workspace, or surface id.
    static func hostID(of identifier: String) -> UUID? {
        guard owns(identifier) else { return nil }
        let rest = identifier.dropFirst(prefix.count)
        let hostPart = rest.split(separator: separator, maxSplits: 1).first.map(String.init) ?? String(rest)
        return UUID(uuidString: hostPart)
    }

    /// The host-local part of a scoped workspace or surface id.
    static func localID(of identifier: String) -> String? {
        guard owns(identifier), let index = identifier.firstIndex(of: separator) else { return nil }
        return String(identifier[identifier.index(after: index)...])
    }
}
