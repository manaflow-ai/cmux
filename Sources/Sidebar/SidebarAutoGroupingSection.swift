import Foundation

/// One derived sidebar section in an automatic Group By mode.
struct SidebarAutoGroupingSection: Equatable, Sendable {
    /// Stable identity, for example `host:local` or `status:running`.
    let key: String
    let title: String
    /// SF Symbol drawn in the section header.
    let symbol: String
    /// Members in the window's `tabs` order.
    let workspaceIds: [UUID]

    /// The synthetic `WorkspaceGroup` id rendered for this section.
    var groupId: UUID { Self.groupId(forKey: key) }

    /// Derives a UUID from a section key. The same key gives the same id in
    /// every render and every launch, so SwiftUI and the AppKit table keep row
    /// identity while a section's members change. Swift's `Hasher` is seeded
    /// per process, so this uses two FNV-1a passes instead.
    static func groupId(forKey key: String) -> UUID {
        let bytes = Array("cmux.sidebar.auto-section:\(key)".utf8)
        let high = fnv1a64(bytes, basis: 0xcbf2_9ce4_8422_2325)
        let low = fnv1a64(bytes, basis: 0x8422_2325_cbf2_9ce4)
        var raw = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            raw[index] = UInt8(truncatingIfNeeded: high >> (56 - 8 * index))
            raw[index + 8] = UInt8(truncatingIfNeeded: low >> (56 - 8 * index))
        }
        // Mark it as a version 8 (custom), RFC 4122 variant UUID so it can
        // never equal a random version 4 workspace or group id.
        raw[6] = (raw[6] & 0x0f) | 0x80
        raw[8] = (raw[8] & 0x3f) | 0x80
        return UUID(uuid: (
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
            raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]
        ))
    }

    private static func fnv1a64(_ bytes: [UInt8], basis: UInt64) -> UInt64 {
        var hash = basis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
