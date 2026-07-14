public import CMUXMobileCore
public import Foundation

/// Typed result of `mobile.terminal.scroll`. Modern hosts echo the interaction
/// epoch and newest client revision so optimistic local work reconciles only
/// with the matching Mac mutation. Older hosts may omit those fields.
public struct MobileTerminalScrollResponse: Decodable, Sendable {
    /// Whether the host accepted the scroll mutation.
    public let accepted: Bool?
    /// Interaction epoch echoed by modern hosts.
    public let interactionEpoch: UInt64?
    /// Latest client scroll revision acknowledged by the host.
    public let clientScrollRevision: UInt64?
    /// Monotonic host render revision for this terminal surface.
    public let renderRevision: UInt64?
    /// Authoritative render-grid snapshot returned for prefetch requests.
    public let renderGrid: MobileTerminalRenderGridFrame?

    private enum CodingKeys: String, CodingKey {
        case accepted
        case interactionEpoch = "interaction_epoch"
        case clientScrollRevision = "client_scroll_revision"
        case renderRevision = "render_revision"
        case renderGrid = "render_grid"
    }

    /// Decodes the scroll response and its optional compatibility fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted)
        interactionEpoch = try container.decodeIfPresent(UInt64.self, forKey: .interactionEpoch)
        clientScrollRevision = try container.decodeIfPresent(UInt64.self, forKey: .clientScrollRevision)
        renderRevision = try container.decodeIfPresent(UInt64.self, forKey: .renderRevision)
        renderGrid = try container.decodeIfPresent(MobileTerminalRenderGridFrame.self, forKey: .renderGrid)
    }

    /// Decodes a scroll response from JSON data.
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
