// Privacy and padding of a Linux Logger value (Logger+Linux.swift).

#if !canImport(os)
/// Whether an interpolated value is written or redacted (`os.OSLogPrivacy`).
public struct OSLogPrivacy: Equatable, Sendable {
    /// How a redacted value is shown.
    public struct Mask: Equatable, Sendable {
        let hashes: Bool

        /// `<private>`.
        public static let none = Mask(hashes: false)
        /// `<mask.hash: '…'>`, a hash of the value, so that equal values can be matched.
        public static let hash = Mask(hashes: true)
    }

    enum Kind: Equatable {
        case auto, `public`, `private`, sensitive
    }

    let kind: Kind
    let mask: Mask

    public static let auto = OSLogPrivacy(kind: .auto, mask: .none)
    public static let `public` = OSLogPrivacy(kind: .public, mask: .none)
    public static let `private` = OSLogPrivacy(kind: .private, mask: .none)
    public static let sensitive = OSLogPrivacy(kind: .sensitive, mask: .none)

    public static func auto(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: .auto, mask: mask) }
    public static func `private`(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: .private, mask: mask) }
    public static func sensitive(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: .sensitive, mask: mask) }

    /// Whether a value is redacted. `auto` redacts text and objects and writes numbers and booleans, as the
    /// unified log does.
    func redacts(scalar: Bool) -> Bool {
        switch kind {
        case .public: false
        case .private, .sensitive: true
        case .auto: !scalar
        }
    }

    /// `text` as written under this privacy.
    func apply(_ text: String, scalar: Bool) -> String {
        guard redacts(scalar: scalar) else { return text }
        guard mask.hashes else { return "<private>" }
        // FNV-1a 64 of the UTF-8 bytes.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return "<mask.hash: '\(String(hash, radix: 16))'>"
    }
}

/// The padding of an interpolated value (`os.OSLogStringAlignment`).
public struct OSLogStringAlignment: Sendable {
    let columns: Int
    let leftAligned: Bool

    /// No padding.
    public static let none = OSLogStringAlignment(columns: 0, leftAligned: false)

    /// Pads the value with spaces after it to `columns` characters.
    public static func left(columns: Int) -> OSLogStringAlignment {
        OSLogStringAlignment(columns: columns, leftAligned: true)
    }

    /// Pads the value with spaces before it to `columns` characters.
    public static func right(columns: Int) -> OSLogStringAlignment {
        OSLogStringAlignment(columns: columns, leftAligned: false)
    }

    func apply(_ text: String) -> String {
        let padding = columns - text.count
        guard padding > 0 else { return text }
        let spaces = String(repeating: " ", count: padding)
        return leftAligned ? text + spaces : spaces + text
    }
}
#endif
