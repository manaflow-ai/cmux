import Foundation

/// A typed render-grid delivery unit with explicit scrollback ownership.
public struct MobileTerminalRenderGridEnvelope: Codable, Equatable, Sendable {
    /// The semantic role of the carried render-grid frame.
    public enum Role: String, Codable, Equatable, Sendable {
        /// A full terminal snapshot that replaces the local mirror's history.
        case snapshot
        /// A live viewport delta that must not replace local scrollback history.
        case viewportDelta = "viewport_delta"
    }

    /// Validation failures for invalid render-grid envelope/frame pairings.
    public enum ValidationError: Error, Equatable, Sendable {
        /// Snapshot envelopes must carry a full frame.
        case snapshotRequiresFullFrame
        /// Viewport delta envelopes must carry a delta frame.
        case viewportDeltaRequiresDeltaFrame
    }

    /// The semantic role of ``frame``.
    public let role: Role
    /// The render-grid frame to synthesize into VT bytes.
    public let frame: MobileTerminalRenderGridFrame

    /// Creates a typed render-grid envelope.
    ///
    /// - Parameter role: The semantic role of `frame`.
    /// - Parameter frame: The render-grid frame.
    /// - Throws: ``ValidationError`` when the frame shape does not match `role`.
    public init(role: Role, frame: MobileTerminalRenderGridFrame) throws {
        switch role {
        case .snapshot:
            guard frame.full else { throw ValidationError.snapshotRequiresFullFrame }
        case .viewportDelta:
            guard !frame.full else { throw ValidationError.viewportDeltaRequiresDeltaFrame }
        }
        self.role = role
        self.frame = frame
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(Role.self, forKey: .role)
        let frame = try container.decode(MobileTerminalRenderGridFrame.self, forKey: .frame)
        try self.init(role: role, frame: frame)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(frame, forKey: .frame)
    }

    /// Creates a history-owning full snapshot envelope.
    ///
    /// - Parameter frame: A full render-grid frame.
    /// - Returns: A snapshot envelope.
    /// - Throws: ``ValidationError/snapshotRequiresFullFrame`` when `frame` is a delta.
    public static func snapshot(_ frame: MobileTerminalRenderGridFrame) throws -> Self {
        try Self(role: .snapshot, frame: frame)
    }

    /// Creates a history-preserving live viewport delta envelope.
    ///
    /// - Parameter frame: A delta render-grid frame.
    /// - Returns: A viewport-delta envelope.
    /// - Throws: ``ValidationError/viewportDeltaRequiresDeltaFrame`` when `frame` is full.
    public static func viewportDelta(_ frame: MobileTerminalRenderGridFrame) throws -> Self {
        try Self(role: .viewportDelta, frame: frame)
    }

    /// Whether this envelope replaces the local mirror's scrollback history.
    public var ownsScrollback: Bool {
        role == .snapshot && frame.activeScreen == .primary
    }

    /// Number of primary-screen scrollback rows carried by this envelope.
    public var scrollbackRowsForLocalMirror: Int? {
        ownsScrollback ? frame.scrollbackRows : nil
    }

    /// Full snapshot grid dimensions, when this envelope carries a snapshot.
    public var replayGrid: (columns: Int, rows: Int)? {
        role == .snapshot ? (frame.columns, frame.rows) : nil
    }

    /// True when this envelope fully replaces the current visible viewport.
    public var isReplaceableViewportDelta: Bool {
        guard role == .viewportDelta else { return false }
        let cleared = Set(frame.clearedRows)
        guard cleared.count >= frame.rows else { return false }
        for row in 0..<frame.rows where !cleared.contains(row) {
            return false
        }
        return true
    }

    /// Converts this envelope to a JSON object for RPC/event payloads.
    ///
    /// - Returns: A JSON object containing `role` and `render_grid`.
    /// - Throws: An encoding error if the envelope cannot be serialized.
    public func jsonObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// Decodes a render-grid envelope from raw JSON data.
    ///
    /// - Parameter data: The JSON-encoded envelope.
    /// - Returns: The decoded and validated envelope.
    /// - Throws: A decoding or validation error if the payload is malformed.
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case frame = "render_grid"
    }
}
