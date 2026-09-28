import CmuxTerminalSizing
import Foundation

/// Converts sizing wire values between `Codable` types and the
/// `[String: Any]` dictionaries the mobile RPC and cmux-tui protocol use.
public struct TerminalSizingWireCoder: Sendable {
    /// Creates a coder.
    public init() {}

    /// The wire JSON object for a size state.
    ///
    /// - Parameter state: the state to encode.
    /// - Returns: a JSON-compatible dictionary, or an empty one if encoding fails.
    public func jsonObject(_ state: TerminalSizingState) -> [String: Any] {
        jsonObject(encodable: state) ?? [:]
    }

    /// The wire JSON object for a policy.
    ///
    /// - Parameter policy: the policy to encode.
    /// - Returns: a JSON-compatible dictionary.
    public func jsonObject(_ policy: TerminalSizingPolicy) -> [String: Any] {
        jsonObject(encodable: policy) ?? ["mode": policy.mode.rawValue]
    }

    /// The wire JSON object for a detach actor.
    ///
    /// - Parameter actor: the actor to encode.
    /// - Returns: a JSON-compatible dictionary.
    public func jsonObject(_ actor: TerminalDetachActor) -> [String: Any] {
        jsonObject(encodable: actor) ?? [:]
    }

    /// The `mobile.terminal.detached` payload.
    ///
    /// - Parameters:
    ///   - surfaceID: the surface the phone was detached from.
    ///   - detachment: the detach record.
    /// - Returns: `{surface_id, reason, by, at}` with `at` in ISO 8601.
    public func detachedPayload(surfaceID: String, detachment: TerminalSharingDetachment) -> [String: Any] {
        var payload: [String: Any] = [
            "surface_id": surfaceID,
            "reason": detachment.reason.wireValue,
            "at": ISO8601DateFormatter().string(from: detachment.at),
        ]
        payload["by"] = detachment.actor.map { jsonObject($0) as Any } ?? NSNull()
        return payload
    }

    /// Decodes a size state from a wire value.
    ///
    /// - Parameter value: a dictionary from `JSONSerialization`.
    /// - Returns: the state, or `nil` when the value is not a valid state.
    public func state(from value: Any?) -> TerminalSizingState? {
        decode(TerminalSizingState.self, from: value)
    }

    /// Decodes a policy from a wire value.
    ///
    /// - Parameter value: a dictionary from `JSONSerialization`.
    /// - Returns: the policy, or `nil` when the value is not a valid policy.
    public func policy(from value: Any?) -> TerminalSizingPolicy? {
        guard let object = value as? [String: Any],
              let mode = object["mode"] as? String,
              TerminalSizingMode(rawValue: mode) != nil else { return nil }
        return decode(TerminalSizingPolicy.self, from: object)
    }

    /// Decodes a detach actor from a wire value.
    ///
    /// - Parameter value: a dictionary from `JSONSerialization`, or `NSNull`.
    /// - Returns: the actor, or `nil` when absent.
    public func actor(from value: Any?) -> TerminalDetachActor? {
        decode(TerminalDetachActor.self, from: value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func jsonObject<T: Encodable>(encodable: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(encodable) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
