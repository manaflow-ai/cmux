public import CmuxTerminalSizing
public import Foundation

/// The `mobile.terminal.size_state` push:
/// `{surface_id, state, self_participant_id}`.
public struct MobileTerminalSizeStateEvent: Decodable, Sendable, Equatable {
    /// The terminal surface the state belongs to.
    public let surfaceID: String
    /// The published size state.
    public let state: TerminalSizingState
    /// This phone's participant id, when the host sent it.
    public let selfParticipantID: String?

    private enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_id"
        case state
        case selfParticipantID = "self_participant_id"
    }

    /// Decodes the event payload.
    /// - Parameter data: The raw push payload.
    /// - Returns: The event.
    /// - Throws: A decoding error when the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileTerminalSizeStateEvent {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

/// The `mobile.terminal.detached` push: `{surface_id, reason, by, at}`.
public struct MobileTerminalDetachedEvent: Decodable, Sendable, Equatable {
    /// The terminal surface this phone was detached from.
    public let surfaceID: String
    /// The reason and, for `disconnected-by`, the actor.
    public let reason: TerminalDetachReason
    /// When the host detached the view, from ISO 8601 `at`.
    public let at: Date?

    private enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_id"
        case reason
        case by
        case at
    }

    /// Creates an event.
    public init(surfaceID: String, reason: TerminalDetachReason, at: Date?) {
        self.surfaceID = surfaceID
        self.reason = reason
        self.at = at
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaceID = try container.decode(String.self, forKey: .surfaceID)
        let rawReason = try container.decodeIfPresent(String.self, forKey: .reason)
        let actor = try? container.decodeIfPresent(TerminalDetachActor.self, forKey: .by)
        reason = TerminalDetachReason(wireValue: rawReason, by: actor)
        let rawAt = try? container.decodeIfPresent(String.self, forKey: .at)
        at = rawAt.flatMap(Self.parseDate)
    }

    /// Parses ISO 8601 with or without fractional seconds.
    /// - Parameter raw: The wire timestamp.
    /// - Returns: The date, or `nil` when unparseable.
    public static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Decodes the event payload.
    /// - Parameter data: The raw push payload.
    /// - Returns: The event.
    /// - Throws: A decoding error when the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileTerminalDetachedEvent {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

/// The sizing fields of a `mobile.terminal.replay` or
/// `mobile.terminal.reattach` result: `size_state` and `self_participant_id`.
///
/// Decoded separately from the replay frame so a malformed or absent size
/// state never fails the replay itself.
public struct MobileTerminalReplaySizing: Decodable, Sendable, Equatable {
    /// The published size state, when the host sent one.
    public let sizeState: TerminalSizingState?
    /// This phone's participant id, when the host sent one.
    public let selfParticipantID: String?

    private enum CodingKeys: String, CodingKey {
        case sizeState = "size_state"
        case selfParticipantID = "self_participant_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sizeState = try? container.decodeIfPresent(TerminalSizingState.self, forKey: .sizeState)
        selfParticipantID = try? container.decodeIfPresent(String.self, forKey: .selfParticipantID)
    }

    /// Decodes the sizing fields, or `nil` when the result carries neither.
    /// - Parameter data: The raw RPC result.
    /// - Returns: The sizing fields, or `nil`.
    public static func decodeIfPresent(_ data: Data) -> MobileTerminalReplaySizing? {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.sizeState != nil || decoded.selfParticipantID != nil else {
            return nil
        }
        return decoded
    }
}
