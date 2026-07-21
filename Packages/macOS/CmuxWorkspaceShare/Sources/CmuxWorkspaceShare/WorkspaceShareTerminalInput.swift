internal import Foundation

/// One bounded viewer input event targeting an exact terminal in a shared layout revision.
public struct WorkspaceShareTerminalInput: Codable, Equatable, Sendable {
    /// Maximum UTF-8 bytes accepted in one committed-text event.
    public static let maximumTextBytes = 4_096
    /// Largest layout revision JavaScript can represent without losing precision.
    public static let maximumSafeLayoutRevision: UInt64 = 9_007_199_254_740_991

    /// How the native Ghostty surface should interpret ``data``.
    public enum Kind: String, Codable, Sendable {
        /// Unicode text committed by a keyboard, input method, or paste.
        case text
        /// A bounded semantic key name such as `enter`, `left`, or `ctrl-c`.
        case key
    }

    /// Stable terminal surface identifier.
    public let surfaceId: String
    /// Authoritative workspace layout revision shown to the viewer.
    public let layoutRevision: UInt64
    /// Text or semantic key input.
    public let kind: Kind
    /// Bounded committed text or a semantic key name.
    public let data: String

    /// Creates an input event after applying the native protocol bounds.
    ///
    /// - Parameters:
    ///   - surfaceId: Exact shared terminal surface identifier.
    ///   - layoutRevision: Workspace layout revision the viewer interacted with.
    ///   - kind: Text or semantic key input.
    ///   - data: Committed text or semantic key name.
    public init(
        surfaceId: String,
        layoutRevision: UInt64,
        kind: Kind,
        data: String
    ) throws {
        guard UUID(uuidString: surfaceId) != nil else {
            throw WorkspaceShareTerminalInputError.invalidSurfaceId
        }
        guard layoutRevision <= Self.maximumSafeLayoutRevision else {
            throw WorkspaceShareTerminalInputError.invalidLayoutRevision
        }
        switch kind {
        case .text:
            guard Self.isValidText(data) else {
                throw WorkspaceShareTerminalInputError.invalidText
            }
        case .key:
            guard Self.isValidKey(data) else {
                throw WorkspaceShareTerminalInputError.invalidKey
            }
        }
        self.surfaceId = surfaceId
        self.layoutRevision = layoutRevision
        self.kind = kind
        self.data = data
    }

    /// Decodes and validates an untrusted viewer input event.
    /// - Parameter decoder: Decoder positioned at the input payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            surfaceId: container.decode(String.self, forKey: .surfaceId),
            layoutRevision: container.decode(UInt64.self, forKey: .layoutRevision),
            kind: container.decode(Kind.self, forKey: .kind),
            data: container.decode(String.self, forKey: .data)
        )
    }

    private static func isValidText(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumTextBytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x1F && !(0x7F...0x9F).contains(scalar.value)
        }
    }

    private static func isValidKey(_ value: String) -> Bool {
        switch value {
        case "enter", "backspace", "tab", "shift-tab", "escape", "up", "down", "left", "right",
             "home", "end", "delete":
            return true
        default:
            let scalars = value.unicodeScalars
            guard scalars.count == 6, value.hasPrefix("ctrl-") else { return false }
            let key = scalars.last?.value ?? 0
            return (0x61...0x7A).contains(key) || key == 0x5C
        }
    }
}

/// Validation errors for viewer-to-terminal input.
public enum WorkspaceShareTerminalInputError: Error, Equatable, Sendable {
    case invalidSurfaceId
    case invalidLayoutRevision
    case invalidText
    case invalidKey
}
