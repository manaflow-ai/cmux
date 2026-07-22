import Foundation

/// Selects the richest hook payload that fits transport byte budgets.
public struct AgentHookPayloadCompactor: Sendable {
    /// Creates a hook payload compactor.
    public init() {}

    /// Reports whether a payload fits its raw and JSON-encoded byte budgets.
    ///
    /// - Parameters:
    ///   - payload: The candidate payload string.
    ///   - maximumPayloadBytes: The maximum raw UTF-8 byte count.
    ///   - maximumEncodedPayloadBytes: An optional maximum after the payload is
    ///     encoded as a JSON string field.
    /// - Returns: `true` when both configured budgets are satisfied.
    public func payloadFits(
        _ payload: String,
        maximumPayloadBytes: Int,
        maximumEncodedPayloadBytes: Int? = nil
    ) -> Bool {
        guard payload.utf8.count <= maximumPayloadBytes else { return false }
        guard let maximumEncodedPayloadBytes else { return true }
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: ["payload": payload],
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return false
        }
        return encoded.count <= maximumEncodedPayloadBytes
    }

    /// Returns the first candidate that fits, or a neutral empty object.
    ///
    /// Candidates should be ordered from richest to most compact so transport
    /// degradation preserves as much hook context as possible.
    ///
    /// - Parameters:
    ///   - candidates: Payload candidates ordered by preference.
    ///   - maximumPayloadBytes: The maximum raw UTF-8 byte count.
    ///   - maximumEncodedPayloadBytes: An optional maximum after the payload is
    ///     encoded as a JSON string field.
    /// - Returns: The first fitting candidate, or `{}` when none fit.
    public func firstFittingPayload(
        in candidates: [String],
        maximumPayloadBytes: Int,
        maximumEncodedPayloadBytes: Int? = nil
    ) -> String {
        candidates.first {
            payloadFits(
                $0,
                maximumPayloadBytes: maximumPayloadBytes,
                maximumEncodedPayloadBytes: maximumEncodedPayloadBytes
            )
        } ?? "{}"
    }
}
