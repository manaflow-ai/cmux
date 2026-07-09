import Foundation

/// A stable, content-derived command identifier for the dynamic palette
/// contributions whose keys are runtime values (a cmux.json issue id, a
/// workspace-color name, an extension sidebar provider id) rather than a fixed
/// literal.
///
/// The identifier is the contribution's `domain` prefix joined to the FNV-1a
/// 64-bit hash (hex, lowercase) of the UTF-8 bytes of `key`. The host builds a
/// contribution with this `value` and later registers the matching handler
/// under the same `value`, so the two derivations must agree byte-for-byte.
/// Both sides go through this one type, eliminating the three hand-inlined hash
/// loops that previously lived in `ContentView` and had to be kept identical by
/// inspection.
///
/// The hash is part of the *frozen wire format*: it appears in command-palette
/// snapshots and config-action resolution, so the prefixes and the FNV-1a
/// constants here are fixed and must not change.
public struct CommandPaletteHashedCommandID: Sendable, Equatable {
    /// The contribution family a hashed id belongs to. Each case carries the
    /// exact command-id prefix the legacy `ContentView` builders used.
    public enum Domain: String, Sendable, CaseIterable {
        /// cmux.json configuration-issue commands (`palette.cmuxConfig.issue.<hash>`).
        case cmuxConfigIssue
        /// Workspace-color commands (`palette.workspaceColor.<hash>`).
        case workspaceColor
        /// Extension-sidebar switch commands (`palette.extensionSidebar.<hash>`).
        case extensionSidebar

        /// The literal command-id prefix, including the trailing dot.
        public var prefix: String {
            switch self {
            case .cmuxConfigIssue:
                return "palette.cmuxConfig.issue."
            case .workspaceColor:
                return "palette.workspaceColor."
            case .extensionSidebar:
                return "palette.extensionSidebar."
            }
        }
    }

    /// The fully-formed command identifier (`<domain.prefix><fnv1a-hex>`).
    public let value: String

    /// Derives the identifier for `key` in `domain`.
    ///
    /// - Parameters:
    ///   - domain: The contribution family, supplying the id prefix.
    ///   - key: The runtime key (issue id, color name, or provider id) whose
    ///     UTF-8 bytes are hashed.
    public init(domain: Domain, key: String) {
        self.value = domain.prefix + Self.fnv1aHex(key)
    }

    /// The FNV-1a 64-bit hash of `text`'s UTF-8 bytes, rendered as lowercase
    /// hexadecimal. Matches the legacy inline derivation exactly.
    private static func fnv1aHex(_ text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
