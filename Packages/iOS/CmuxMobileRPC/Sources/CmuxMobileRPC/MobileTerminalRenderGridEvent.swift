public import CMUXMobileCore
public import Foundation

/// Typed decoder for a `terminal.render_grid` push-event payload that nests the
/// frame under a `render_grid` key.
///
/// Some hosts wrap the frame (`{"render_grid": { ... }}`) and some emit the bare
/// frame as the whole payload. This DTO decodes the wrapped form; the caller
/// falls back to decoding the payload directly as a
/// ``MobileTerminalRenderGridFrame`` when ``frame`` is `nil`.
public struct MobileTerminalRenderGridEvent: Decodable, Sendable {
    /// The typed render-grid envelope, if the host provided one.
    public let envelope: MobileTerminalRenderGridEnvelope?
    /// The nested render-grid frame, if the payload used the wrapped form.
    public let frame: MobileTerminalRenderGridFrame?
    /// Whether the payload opted into typed render-grid envelope semantics.
    public let hasRole: Bool

    private enum CodingKeys: String, CodingKey {
        case role
        case frame = "render_grid"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasRole = container.contains(.role)
        if hasRole {
            envelope = try? MobileTerminalRenderGridEnvelope(from: decoder)
        } else {
            envelope = nil
        }
        frame = try container.decodeIfPresent(MobileTerminalRenderGridFrame.self, forKey: .frame)
    }

    /// Decode a wrapped render-grid event from a raw JSON payload.
    /// - Parameter data: The event payload JSON.
    /// - Returns: The decoded event.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileTerminalRenderGridEvent {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// The live terminal event as a viewport-delta envelope.
    ///
    /// New hosts emit the typed envelope directly. Older hosts emitted a wrapped
    /// or bare render-grid frame; normalize those frames here so the shell's
    /// downstream output path still handles one protocol shape and never lets a
    /// live event own scrollback metadata.
    public static func liveViewportEnvelope(from data: Data) -> MobileTerminalRenderGridEnvelope? {
        if let event = try? decode(data) {
            if event.hasRole {
                guard let envelope = event.envelope, envelope.role == .viewportDelta else {
                    return nil
                }
                return envelope
            }
            if let envelope = event.envelope, envelope.role == .viewportDelta {
                return envelope
            }
            if let frame = event.frame {
                return viewportDeltaEnvelope(fromLegacyFrame: frame)
            }
        }
        if let envelope = try? MobileTerminalRenderGridEnvelope.decode(data),
           envelope.role == .viewportDelta {
            return envelope
        }
        if payloadContainsRole(data) {
            return nil
        }
        if let frame = try? MobileTerminalRenderGridFrame.decode(data) {
            return viewportDeltaEnvelope(fromLegacyFrame: frame)
        }
        return nil
    }

    private static func payloadContainsRole(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["role"] != nil
    }

    private static func viewportDeltaEnvelope(
        fromLegacyFrame frame: MobileTerminalRenderGridFrame
    ) -> MobileTerminalRenderGridEnvelope? {
        if frame.full {
            guard let delta = try? frame.filteredRows(Set(0..<frame.rows), full: false) else {
                return nil
            }
            return try? MobileTerminalRenderGridEnvelope.viewportDelta(delta)
        }
        return try? MobileTerminalRenderGridEnvelope.viewportDelta(frame)
    }
}
