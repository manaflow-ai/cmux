// SPDX-License-Identifier: MIT

import Foundation

/// Stable, transport-neutral reference to a single cmux terminal surface.
///
/// Two interchangeable forms:
/// - ``uuid(_:)`` — persistent ``UUID``.
/// - ``ref(kind:ordinal:)`` — short human-friendly form like `"surface:1"`.
public enum SurfaceHandle: Hashable, Sendable, Codable {
    /// A persistent ``UUID`` that identifies the surface for its lifetime.
    case uuid(UUID)
    /// A short human-friendly reference of the form `kind:ordinal`
    /// (e.g. `"surface:1"`, `"workspace:42"`).
    case ref(kind: String, ordinal: Int)

    /// Parses a handle string. Accepts a canonical UUID (case-insensitive)
    /// or `kind:ordinal` with `kind` in `[a-z]+` and `ordinal` a positive
    /// decimal integer. Returns `nil` for any other shape.
    public static func parse(_ s: String) -> SurfaceHandle? {
        if let u = UUID(uuidString: s) { return .uuid(u) }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let kind = String(parts[0])
        let ordStr = String(parts[1])
        guard !kind.isEmpty,
              kind.allSatisfy({ $0.isASCII && $0.isLetter && $0.isLowercase })
        else { return nil }
        guard let ord = Int(ordStr), ord > 0 else { return nil }
        return .ref(kind: kind, ordinal: ord)
    }

    /// Canonical string form. Round-trips through ``parse(_:)``.
    public var stringValue: String {
        switch self {
        case .uuid(let u): return u.uuidString
        case .ref(let k, let o): return "\(k):\(o)"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let parsed = SurfaceHandle.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "bad SurfaceHandle: \(raw)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(stringValue)
    }
}
