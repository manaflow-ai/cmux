import Foundation

/// The parameters a client sends to open an attach: which surface, how big the
/// client's terminal is, whether it wants input, and which wire version it
/// speaks. This is the validated, typed form of the `surface.attach_pty`
/// request params.
public struct AttachRequest: Sendable, Equatable {
    /// The current attach wire version. Bumped only on incompatible changes.
    public static let currentVersion = 1

    /// A surface reference (UUID string or short ref like `surface:3`); resolved
    /// to a concrete surface on the host side, not here.
    public let surface: String
    public let size: SurfaceSize
    /// When true the client only views output and never injects input.
    public let readOnly: Bool
    public let version: Int

    public init(surface: String, size: SurfaceSize, readOnly: Bool = false, version: Int = AttachRequest.currentVersion) {
        self.surface = surface
        self.size = size
        self.readOnly = readOnly
        self.version = version
    }
}

/// Why an attach request was rejected before any streaming started. Each case
/// names the offending field so the host can return a precise v2 error and the
/// client can print something a human can act on.
public enum AttachRequestError: Error, Equatable, Sendable {
    case missingSurface
    case invalidColumns(Int)
    case invalidRows(Int)
    case unsupportedVersion(Int)
    /// `v` was present but not an integer (e.g. `"abc"`, `1.5`, `true`). A
    /// missing `v` defaults to the current version and is not an error; a
    /// malformed one is rejected rather than silently coerced.
    case invalidVersion
}

public enum AttachHandshake {
    /// The largest terminal dimension we accept. Guards against a malformed or
    /// hostile client forcing an absurd PTY size.
    public static let maxDimension = 10_000

    /// Parse and validate the params object of a `surface.attach_pty` request.
    ///
    /// `surface` is required and non-empty. `cols`/`rows` must be present and in
    /// `1...maxDimension`. `read_only` defaults to false. `v` (version) defaults
    /// to the current version and must match it. Numeric fields accept either
    /// JSON numbers or numeric strings, mirroring the rest of the v2 contract.
    public static func parse(params: [String: Any]) throws -> AttachRequest {
        guard let surface = (params["surface"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !surface.isEmpty else {
            throw AttachRequestError.missingSurface
        }

        let cols = intValue(params["cols"]) ?? 0
        guard cols >= 1, cols <= maxDimension else {
            throw AttachRequestError.invalidColumns(cols)
        }
        let rows = intValue(params["rows"]) ?? 0
        guard rows >= 1, rows <= maxDimension else {
            throw AttachRequestError.invalidRows(rows)
        }

        // Accept any version this host understands ([1, currentVersion]) rather
        // than only the latest, so a newer client can still attach to an older
        // host during a staged rollout. Only versions above what we know are
        // rejected. A missing `v` defaults to the current version (older clients
        // predate the field); a present-but-non-integer `v` is malformed and is
        // rejected rather than silently coerced to the current version.
        let version: Int
        if let rawVersion = params["v"] {
            guard let parsed = intValue(rawVersion) else {
                throw AttachRequestError.invalidVersion
            }
            version = parsed
        } else {
            version = AttachRequest.currentVersion
        }
        guard version >= 1, version <= AttachRequest.currentVersion else {
            throw AttachRequestError.unsupportedVersion(version)
        }

        let readOnly = boolValue(params["read_only"]) ?? false

        return AttachRequest(
            surface: surface,
            size: SurfaceSize(cols: cols, rows: rows),
            readOnly: readOnly,
            version: version
        )
    }

    /// Accept integers, integer-valued doubles, and numeric strings; reject
    /// fractional numbers and non-numeric strings. Mirrors the port-field
    /// coercion the v2 socket contract documents.
    static func intValue(_ raw: Any?) -> Int? {
        // A JSON boolean decodes to a CFBoolean-backed NSNumber; reject it so
        // `cols: true` / `v: true` can't validate as 1/0. Discriminate by the
        // CoreFoundation type id rather than `is Bool`, because `NSNumber(1)
        // as? Bool` also succeeds (the 0/1 bridging trap) and would wrongly
        // reject the integers 0 and 1 - including version 1, the only currently
        // valid `v`, which round-trips through JSON as an NSNumber.
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        switch raw {
        case let value as Int:
            return value
        case let value as Double:
            return value.rounded() == value ? Int(value) : nil
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    static func boolValue(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool:
            return value
        case let value as String:
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        case let value as Int:
            return value != 0
        default:
            return nil
        }
    }
}
