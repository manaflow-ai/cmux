internal import Foundation

/// Normalizes and validates the caller-owned identity accepted by workspace-group creation.
///
/// Both `external_id` and `idempotency_key` are accepted spellings of the same
/// window-scoped identity. Transport adapters convert their raw parameter shape
/// into ``Input`` and use this value to keep trimming, blank-value, and alias
/// agreement rules identical across every RPC surface.
public struct WorkspaceGroupIdentityResolution: Equatable, Sendable {
    /// The wire field being validated, used to keep adapter error data precise.
    public enum Field: String, Equatable, Sendable {
        /// The durable caller-owned identity field.
        case externalID = "external_id"
        /// The retry-oriented alias for ``externalID``.
        case idempotencyKey = "idempotency_key"
    }

    /// A raw field value after transport decoding but before validation.
    public enum Input: Equatable, Sendable {
        /// The field was omitted or explicitly set to null.
        case absent
        /// The field carried a string that still needs trimming and validation.
        case string(String)
        /// The field was present with a non-string, non-null value.
        case invalid
    }

    /// Why the supplied identity could not be accepted.
    public enum ValidationError: Error, Equatable, Sendable {
        /// A present field was not a string.
        case nonString(field: Field)
        /// A string field contained only whitespace.
        case empty(field: Field)
        /// Both aliases were supplied with different normalized values.
        case mismatchedAliases
    }

    /// The normalized identity, or nil when neither alias was supplied.
    public let value: String?

    /// Validates and normalizes the two accepted identity aliases.
    ///
    /// - Parameters:
    ///   - externalID: The decoded `external_id` field.
    ///   - idempotencyKey: The decoded `idempotency_key` field.
    /// - Throws: ``ValidationError`` when a present field is malformed or the
    ///   two aliases disagree after trimming.
    public init(
        externalID: Input = .absent,
        idempotencyKey: Input = .absent
    ) throws {
        let normalizedExternalID = try Self.normalize(externalID, field: .externalID)
        let normalizedIdempotencyKey = try Self.normalize(idempotencyKey, field: .idempotencyKey)
        if let normalizedExternalID,
           let normalizedIdempotencyKey,
           normalizedExternalID != normalizedIdempotencyKey {
            throw ValidationError.mismatchedAliases
        }
        value = normalizedExternalID ?? normalizedIdempotencyKey
    }

    private static func normalize(_ input: Input, field: Field) throws -> String? {
        switch input {
        case .absent:
            return nil
        case .invalid:
            throw ValidationError.nonString(field: field)
        case .string(let raw):
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw ValidationError.empty(field: field)
            }
            return normalized
        }
    }
}
